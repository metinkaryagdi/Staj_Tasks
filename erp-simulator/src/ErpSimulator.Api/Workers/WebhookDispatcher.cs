using System.Collections.Concurrent;
using ErpSimulator.Application.Abstractions;
using ErpSimulator.Application.Webhooks;
using ErpSimulator.Domain.Webhooks;

namespace ErpSimulator.Api.Workers;

/// <summary>
/// Picks the due webhook deliveries and hands each to <see cref="WebhookSender"/>, at most MaxConcurrentSends at a time.
/// Rows being sent are tracked in memory, so this works for a single simulator instance.
/// </summary>
public sealed class WebhookDispatcher(
    IServiceScopeFactory scopes, IOptions<WebhookOptions> options, TimeProvider time,
    ILogger<WebhookDispatcher> logger) : BackgroundService
{
    private readonly ConcurrentDictionary<long, byte> _inFlight = new();

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

            try { await Task.Delay(await NextWakeAsync(settings, stoppingToken), stoppingToken); }
            catch (OperationCanceledException) { return; }
        }
    }

    /// <summary>Sleeps until the next event is due, but at most PollMilliseconds.</summary>
    private async Task<TimeSpan> NextWakeAsync(WebhookOptions settings, CancellationToken ct)
    {
        var poll = TimeSpan.FromMilliseconds(settings.PollMilliseconds);
        // All send slots busy: a free slot is what we are waiting for, not a due time.
        if (_inFlight.Count >= settings.MaxConcurrentSends)
            return poll;
        try
        {
            await using var scope = scopes.CreateAsyncScope();
            var deliveries = scope.ServiceProvider.GetRequiredService<IWebhookDeliveryStore>();
            var next = await deliveries.NextDueAtAsync(_inFlight.Keys.ToArray(), ct);
            if (next is null)
                return poll;
            // Rounded up to whole milliseconds, so the loop does not wake a fraction of a millisecond too early.
            var wait = TimeSpan.FromMilliseconds(Math.Ceiling((next.Value - time.GetUtcNow()).TotalMilliseconds));
            return wait <= TimeSpan.Zero ? TimeSpan.Zero : wait < poll ? wait : poll;
        }
        catch (Exception ex) when (!ct.IsCancellationRequested)
        {
            logger.LogWarning("Webhook dispatcher could not read the next due time: {Message}", ex.Message);
            return poll;
        }
    }

    private async Task<IReadOnlyList<WebhookDelivery>> DueAsync(int limit, CancellationToken ct)
    {
        await using var scope = scopes.CreateAsyncScope();
        var deliveries = scope.ServiceProvider.GetRequiredService<IWebhookDeliveryStore>();
        return await deliveries.DueAsync(limit, time.GetUtcNow(), _inFlight.Keys.ToArray(), ct);
    }

    private async Task SendAsync(WebhookDelivery row, CancellationToken stoppingToken)
    {
        try
        {
            await using var scope = scopes.CreateAsyncScope();
            await scope.ServiceProvider.GetRequiredService<WebhookSender>().SendAsync(row, stoppingToken);
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
