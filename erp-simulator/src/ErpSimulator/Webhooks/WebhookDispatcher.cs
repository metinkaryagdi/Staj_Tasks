using System.Collections.Concurrent;
using System.Globalization;
using System.Net.Http.Headers;
using System.Text;
using ErpSimulator.Data;
using Microsoft.EntityFrameworkCore;
using Microsoft.Extensions.Options;

namespace ErpSimulator.Webhooks;

/// <summary>
/// Sends due rows of webhook_deliveries to the invoice service. A send that gets no 2xx within Webhooks:TimeoutSeconds
/// is retried after RetryDelaysSeconds[0], [1], ... (5, 10, 20, 40, 80 s); after the last retry the row is Failed.
/// The row is signed at send time with the current timestamp; the body never changes.
/// <para>
/// One simulator instance: rows being sent are tracked in memory so the next poll does not take them again. If the
/// simulator stops mid-send, the row is still Pending and is sent again after the restart (the invoice service
/// ignores a repeated event_id).
/// </para>
/// </summary>
public sealed class WebhookDispatcher(
    IServiceScopeFactory scopes, IHttpClientFactory httpClients, IOptions<WebhookOptions> options, TimeProvider time,
    ILogger<WebhookDispatcher> logger) : BackgroundService
{
    public const string HttpClientName = "webhooks";

    private readonly ConcurrentDictionary<long, byte> _inFlight = new();

    /// <summary>Signs fake events: a key the invoice service does not have.</summary>
    private const string FakeSecret = "not-the-shared-secret-fake-events-are-signed-with-this";

    protected override async Task ExecuteAsync(CancellationToken stoppingToken)
    {
        var settings = options.Value;
        while (!stoppingToken.IsCancellationRequested)
        {
            try
            {
                var free = settings.MaxConcurrentSends - _inFlight.Count;
                if (free > 0)
                {
                    foreach (var row in await DueAsync(free, stoppingToken))
                    {
                        if (_inFlight.TryAdd(row.Id, 0))
                            _ = SendAsync(row, stoppingToken);
                    }
                }
            }
            catch (Exception ex) when (!stoppingToken.IsCancellationRequested)
            {
                // E.g. the database is briefly unavailable: try again on the next poll.
                logger.LogWarning("Webhook dispatcher poll failed: {Message}", ex.Message);
            }

            try { await Task.Delay(settings.PollMilliseconds, stoppingToken); }
            catch (OperationCanceledException) { return; }
        }
    }

    private async Task<List<WebhookDelivery>> DueAsync(int limit, CancellationToken ct)
    {
        await using var scope = scopes.CreateAsyncScope();
        var db = scope.ServiceProvider.GetRequiredService<ErpDbContext>();
        var now = time.GetUtcNow();
        var busy = _inFlight.Keys.ToArray();
        return await db.WebhookDeliveries.AsNoTracking()
            .Where(d => d.Status == DeliveryStatus.Pending && d.DueAt <= now && !busy.Contains(d.Id))
            .OrderBy(d => d.DueAt).ThenBy(d => d.Id)
            .Take(limit)
            .ToListAsync(ct);
    }

    private async Task SendAsync(WebhookDelivery row, CancellationToken stoppingToken)
    {
        try
        {
            var settings = options.Value;
            var attempt = row.AttemptCount + 1;
            var maxAttempts = settings.RetryDelaysSeconds.Length + 1;
            var body = Encoding.UTF8.GetBytes(row.Payload);
            // Replay: an old timestamp with a signature that is valid for it. Fake: a wrong key.
            var signedAt = row.Kind == DeliveryKind.Replay
                ? time.GetUtcNow().AddSeconds(-settings.Problems.ReplayAgeSeconds)
                : time.GetUtcNow();
            var timestamp = signedAt.ToUnixTimeSeconds().ToString(CultureInfo.InvariantCulture);
            var key = row.Kind == DeliveryKind.Fake ? FakeSecret : settings.Secret;

            using var request = new HttpRequestMessage(HttpMethod.Post, settings.TargetUrl);
            request.Content = new ByteArrayContent(body);
            request.Content.Headers.ContentType = new MediaTypeHeaderValue("application/json");
            request.Headers.TryAddWithoutValidation(WebhookSignature.TimestampHeader, timestamp);
            request.Headers.TryAddWithoutValidation(WebhookSignature.SignatureHeader, WebhookSignature.Compute(key, timestamp, body));

            int? httpStatus = null;
            string? error = null;
            var started = time.GetTimestamp();
            try
            {
                using var timeout = CancellationTokenSource.CreateLinkedTokenSource(stoppingToken);
                timeout.CancelAfter(TimeSpan.FromSeconds(settings.TimeoutSeconds));
                using var response = await httpClients.CreateClient(HttpClientName).SendAsync(request, timeout.Token);
                httpStatus = (int)response.StatusCode;
                if (!response.IsSuccessStatusCode)
                    error = $"HTTP {httpStatus}";
            }
            catch (OperationCanceledException) when (stoppingToken.IsCancellationRequested)
            {
                return; // Shutting down: the row stays Pending and is sent again after the restart.
            }
            catch (OperationCanceledException)
            {
                error = $"no answer within {settings.TimeoutSeconds} s";
            }
            catch (HttpRequestException ex)
            {
                error = ex.Message;
            }
            var elapsed = time.GetElapsedTime(started);

            var now = time.GetUtcNow();
            var delivered = error is null;
            // A fake or replayed event that got an answer other than 2xx was rejected: it is not sent again (task rule).
            // Without an answer (timeout, service down) it was not rejected yet, so it is retried like any other.
            var rejected = !delivered && httpStatus is not null && DeliveryKind.NotRetriedWhenRejected(row.Kind);
            var retry = !delivered && !rejected && attempt < maxAttempts;
            var status = delivered ? DeliveryStatus.Delivered
                : rejected ? DeliveryStatus.Rejected
                : retry ? DeliveryStatus.Pending
                : DeliveryStatus.Failed;
            var nextDue = retry ? now.AddSeconds(settings.RetryDelaysSeconds[attempt - 1]) : row.DueAt;
            DateTimeOffset? completedAt = delivered || rejected ? now : null;

            await using (var scope = scopes.CreateAsyncScope())
            {
                var db = scope.ServiceProvider.GetRequiredService<ErpDbContext>();
                await db.WebhookDeliveries
                    .Where(d => d.Id == row.Id && d.Status == DeliveryStatus.Pending)
                    .ExecuteUpdateAsync(s => s
                        .SetProperty(d => d.Status, status)
                        .SetProperty(d => d.AttemptCount, attempt)
                        .SetProperty(d => d.DueAt, nextDue)
                        .SetProperty(d => d.LastHttpStatus, httpStatus)
                        .SetProperty(d => d.LastError, error)
                        .SetProperty(d => d.CompletedAt, completedAt), CancellationToken.None);
            }

            logger.LogInformation(
                "Webhook send event={EventId} type={EventType} invoice={InvoiceNumber} kind={Kind} attempt={Attempt}/{MaxAttempts} " +
                "http={Http} outcome={Outcome} next={Next} elapsed={ElapsedMs}ms error={Error}",
                row.EventId, row.EventType, row.InvoiceNumber, row.Kind, attempt, maxAttempts, httpStatus?.ToString() ?? "-",
                status, retry ? $"{settings.RetryDelaysSeconds[attempt - 1]}s" : "-", (long)elapsed.TotalMilliseconds, error ?? "-");
        }
        catch (Exception ex)
        {
            logger.LogError(ex, "Webhook send event={EventId} failed unexpectedly; it stays Pending", row.EventId);
        }
        finally
        {
            _inFlight.TryRemove(row.Id, out _);
        }
    }
}
