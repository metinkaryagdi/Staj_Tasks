using InvoiceService.Application.Outbox;

namespace InvoiceService.Api.Workers;

/// <summary>
/// Background worker inside the service: takes due erp_outbox entries and sends them, at most
/// <see cref="OutboxOptions.MaxConcurrentSends"/> at the same time. Takes only as many entries as it has free slots,
/// so entries it cannot send yet stay free for another instance.
/// </summary>
public sealed class OutboxWorker(
    IServiceScopeFactory scopes,
    IOptions<OutboxOptions> options,
    ILogger<OutboxWorker> logger) : BackgroundService
{
    /// <summary>Written to erp_outbox.locked_by: the container's host name, so two running copies can be told apart.</summary>
    public static readonly string WorkerId = Environment.MachineName;

    protected override async Task ExecuteAsync(CancellationToken stoppingToken)
    {
        var max = options.Value.MaxConcurrentSends;
        // How long to wait before looking again when nothing is due (Outbox:IdleDelayMilliseconds). Short, so a retry starts
        // close to its next_attempt_at; the query is cheap thanks to the (status, next_attempt_at) index.
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
                    var send = SendAsync(entry, slots);
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

    private async Task SendAsync(ClaimedEntry entry, SemaphoreSlim slots)
    {
        try
        {
            await using var scope = scopes.CreateAsyncScope();
            await scope.ServiceProvider.GetRequiredService<OutboxProcessor>().SendAsync(entry, WorkerId);
        }
        catch (Exception ex)
        {
            // The entry keeps its lock; after Outbox:LockSeconds another worker takes it again.
            logger.LogError("Outbox send failed invoice={InvoiceNumber} attempt={Attempt}: {Message}",
                entry.InvoiceNumber, entry.Attempt, ex.Message);
        }
        finally
        {
            slots.Release();
        }
    }
}
