using System.Globalization;
using System.Text;
using ErpSimulator.Application.Abstractions;
using ErpSimulator.Domain.Webhooks;

namespace ErpSimulator.Application.Webhooks;

/// <summary>
/// Sends one due row of webhook_deliveries and records the outcome. A send that gets no 2xx within
/// Webhooks:TimeoutSeconds is retried RetryDelaysSeconds[0], [1], ... (5, 10, 20, 40, 80 s) after that send started, so
/// sends start 5, 10, 20, 40, 80 s apart even when each one waits the full 5 s for an answer; after the last retry the
/// row is Failed. The row is signed at send time with the current timestamp; the body never changes.
/// Scoped: one instance (and one unit of work) per send.
/// </summary>
public sealed class WebhookSender(
    IWebhookTransport transport, IWebhookDeliveryStore deliveries, IUnitOfWork unitOfWork, IOptions<WebhookOptions> options,
    TimeProvider time, ILogger<WebhookSender> logger)
{
    /// <summary>Signs fake events: a key the invoice service does not have.</summary>
    private const string FakeSecret = "not-the-shared-secret-fake-events-are-signed-with-this";

    /// <summary>
    /// Returns without writing anything when <paramref name="stoppingToken"/> is cancelled during the send: the row stays
    /// Pending and is sent again after the restart.
    /// </summary>
    public async Task SendAsync(WebhookDelivery row, CancellationToken stoppingToken)
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
        var signature = WebhookSignature.Compute(key, timestamp, body);

        var sentAt = time.GetUtcNow();
        var started = time.GetTimestamp();
        WebhookPostResult result;
        try
        {
            result = await transport.PostAsync(
                settings.TargetUrl, body, timestamp, signature, TimeSpan.FromSeconds(settings.TimeoutSeconds), stoppingToken);
        }
        catch (OperationCanceledException) when (stoppingToken.IsCancellationRequested)
        {
            return; // Shutting down: the row stays Pending and is sent again after the restart.
        }
        var (httpStatus, error) = (result.HttpStatus, result.Error);
        var elapsed = time.GetElapsedTime(started);

        var now = time.GetUtcNow();
        var delivered = error is null;
        // Only HTTP 4xx rejects a fake or replayed event permanently. HTTP 5xx and no answer use normal retries.
        var rejected = httpStatus is >= 400 and <= 499 && DeliveryKind.NotRetriedWhenRejected(row.Kind);
        var retry = !delivered && !rejected && attempt < maxAttempts;
        var status = delivered ? DeliveryStatus.Delivered
            : rejected ? DeliveryStatus.Rejected
            : retry ? DeliveryStatus.Pending
            : DeliveryStatus.Failed;
        // Counted from when this send started, not from when it failed: a send without an answer takes the full
        // timeout, and counting from its end would stretch every gap by that much (10, 15, 25 ... instead of 5, 10, 20 ...).
        var nextDue = retry ? sentAt.AddSeconds(settings.RetryDelaysSeconds[attempt - 1]) : row.DueAt;
        DateTimeOffset? completedAt = delivered || rejected ? now : null;

        await using (var transaction = await unitOfWork.BeginAsync(CancellationToken.None))
        {
            var updated = await deliveries.RecordSendAsync(
                row.Id, status, attempt, nextDue, httpStatus, error, completedAt, sentAt);

            // The normal result and its waiting replays commit together, including across a restart.
            if (updated && row.Kind == DeliveryKind.Normal)
            {
                if (delivered)
                    await deliveries.ReleaseReplaysAsync(row.EventId, now.AddSeconds(1));
                else if (status == DeliveryStatus.Failed)
                    await deliveries.SkipReplaysAsync(row.EventId);
            }
            await transaction.CommitAsync(CancellationToken.None);
        }

        logger.LogInformation(
            "Webhook send event={EventId} type={EventType} invoice={InvoiceNumber} kind={Kind} attempt={Attempt}/{MaxAttempts} " +
            "http={Http} outcome={Outcome} next={Next} elapsed={ElapsedMs}ms error={Error}",
            row.EventId, row.EventType, row.InvoiceNumber, row.Kind, attempt, maxAttempts, httpStatus?.ToString() ?? "-",
            status, retry ? $"{settings.RetryDelaysSeconds[attempt - 1]}s" : "-", (long)elapsed.TotalMilliseconds, error ?? "-");
    }
}
