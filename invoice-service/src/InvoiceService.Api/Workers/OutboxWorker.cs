using System.Diagnostics;
using InvoiceService.Application.Outbox;
using InvoiceService.Application.Tracing;

namespace InvoiceService.Api.Workers;

/// <summary>
/// Background worker: takes due outbox entries and sends them, at most MaxConcurrentSends at a time. It takes only as
/// many entries as it has free slots, leaving the rest to other instances.
/// </summary>
public sealed class OutboxWorker(
    IServiceScopeFactory scopes,
    IOptions<OutboxOptions> options,
    ILogger<OutboxWorker> logger) : BackgroundService
{
    /// <summary>Written to erp_outbox.locked_by: the container's host name, so two running copies can be told
    /// apart.</summary>
    public static readonly string WorkerId = Environment.MachineName;

    protected override async Task ExecuteAsync(CancellationToken stoppingToken)
    {
        var max = options.Value.MaxConcurrentSends;
        // Wait before looking again when nothing is due; short, so a retry starts close to its next_attempt_at.
        var idleDelay = TimeSpan.FromMilliseconds(options.Value.IdleDelayMilliseconds);
        using var slots = new SemaphoreSlim(max, max);
        var running = new HashSet<Task>();
        logger.LogInformation("Outbox worker started worker={Worker} maxConcurrentSends={Max}", WorkerId, max);

        try
        {
            while (!stoppingToken.IsCancellationRequested)
            {
                // Wait for at least one free slot, then take as many entries as there are free slots.
                await slots.WaitAsync(stoppingToken);
                var free = slots.CurrentCount + 1;

                IReadOnlyList<ClaimedEntry> claimed;
                Claim claim;
                // One claim takes entries of several invoices, so it is its own trace; each attempt links to it.
                using (var claimSpan = InvoiceTracing.Source.StartActivity("outbox.claim"))
                {
                    var claimStarted = DateTimeOffset.UtcNow;
                    try
                    {
                        await using var scope = scopes.CreateAsyncScope();
                        claimed = await scope.ServiceProvider.GetRequiredService<OutboxProcessor>().ClaimAsync(free, WorkerId, stoppingToken);
                    }
                    catch (Exception ex) when (ex is not OperationCanceledException)
                    {
                        logger.LogWarning("Outbox claim failed: {Message}", ex.Message);
                        claimed = [];
                    }
                    claimSpan?.SetTag("outbox.claimed", claimed.Count);
                    claim = new Claim(claimSpan?.Context ?? default, claimStarted, DateTimeOffset.UtcNow);
                }

                if (claimed.Count == 0)
                {
                    slots.Release();
                    await Task.Delay(idleDelay, stoppingToken);
                    continue;
                }

                // One slot is already held; take one more for every further entry. Only this loop takes slots,
                // so they are free (sends only give slots back).
                for (var i = 1; i < claimed.Count; i++)
                    slots.Wait(0);

                logger.LogInformation("Outbox claimed {Count} entries worker={Worker} inFlight={InFlight}",
                    claimed.Count, WorkerId, max - slots.CurrentCount);

                foreach (var entry in claimed)
                {
                    var send = SendAsync(entry, claim, slots);
                    lock (running) running.Add(send);
                    _ = send.ContinueWith(t => { lock (running) running.Remove(t); }, TaskScheduler.Default);
                }
            }
        }
        catch (OperationCanceledException) when (stoppingToken.IsCancellationRequested)
        {
            // Stopping.
        }

        // Let sends that already reached the ERP record their outcome (bounded by the host's shutdown timeout).
        Task[] pending;
        lock (running) pending = [.. running];
        logger.LogInformation("Outbox worker stopping worker={Worker}, waiting for {Count} sends", WorkerId, pending.Length);
        await Task.WhenAll(pending);
    }

    private async Task SendAsync(ClaimedEntry entry, Claim claim, SemaphoreSlim slots)
    {
        // The attempt continues the invoice's trace (stored with the entry) from the moment the entry was taken.
        using var attempt = InvoiceTracing.StartInTrace("outbox.attempt", entry.TraceParent, claim.Started);
        using (var claimed = InvoiceTracing.Source.StartActivity(
            "outbox.claimed", ActivityKind.Internal, parentContext: default,
            links: claim.Context == default ? null : [new ActivityLink(claim.Context)], startTime: claim.Started))
        {
            claimed?.SetTag("outbox.worker", WorkerId);
            // How long the entry waited after its time had come (next_attempt_at) until a worker took it.
            claimed?.SetTag("outbox.queue_wait_seconds", Math.Max(0, (claim.Started - entry.DueAt).TotalSeconds));
            claimed?.SetEndTime(claim.Ended.UtcDateTime);
        }

        try
        {
            await using var scope = scopes.CreateAsyncScope();
            await scope.ServiceProvider.GetRequiredService<OutboxProcessor>().SendAsync(entry, WorkerId);
        }
        catch (Exception ex)
        {
            // The entry keeps its lock; after Outbox:LockSeconds another worker takes it again.
            attempt?.SetStatus(ActivityStatusCode.Error, ex.Message);
            logger.LogError("Outbox send failed invoice={InvoiceNumber} attempt={Attempt}: {Message}",
                entry.InvoiceNumber, entry.Attempt, ex.Message);
        }
        finally
        {
            slots.Release();
        }
    }

    /// <summary>One claim: its span (for the attempts' links) and when it started and ended.</summary>
    private sealed record Claim(ActivityContext Context, DateTimeOffset Started, DateTimeOffset Ended);
}
