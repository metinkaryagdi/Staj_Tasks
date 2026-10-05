using InvoiceService.Application.Abstractions;
using InvoiceService.Domain.Reconciliation;
using Microsoft.Extensions.DependencyInjection;

namespace InvoiceService.Application.Reconciliation;

/// <summary>A run that was started and holds the lock; <see cref="ReconciliationService.ExecuteAsync"/> does it and lets the lock go.</summary>
public sealed record StartedRun(ReconciliationRun Run, IAsyncDisposable Lease);

/// <summary>
/// Starts runs one at a time, however they are asked for (the schedule, the endpoint, another copy of the service): taking
/// the lock is what starts a run, so a second request while one is going gets nothing.
/// </summary>
public sealed class ReconciliationService(
    IServiceScopeFactory scopes, IReconciliationLock gate, TimeProvider time, ILogger<ReconciliationService> logger)
{
    /// <summary>Takes the lock and records the run as Çalışıyor; null when another run holds the lock.</summary>
    public async Task<StartedRun?> TryStartAsync(CancellationToken ct)
    {
        var lease = await gate.TryAcquireAsync(ct);
        if (lease is null)
            return null;

        try
        {
            await using var scope = scopes.CreateAsyncScope();
            var store = scope.ServiceProvider.GetRequiredService<IReconciliationStore>();

            // Holding the lock, so a run still Çalışıyor belongs to a service that stopped.
            var abandoned = await store.FailAbandonedRunsAsync(time.GetUtcNow(), ct);
            if (abandoned > 0)
                logger.LogWarning("Reconciliation: {Count} run(s) left Çalışıyor by a stopped service were marked Başarısız", abandoned);

            var run = await store.StartRunAsync(time.GetUtcNow(), ct);
            logger.LogInformation("Reconciliation run started run={RunId}", run.Id);
            return new StartedRun(run, lease);
        }
        catch
        {
            await lease.DisposeAsync();
            throw;
        }
    }

    /// <summary>Does the run, records how it ended, then lets the lock go.</summary>
    public async Task ExecuteAsync(StartedRun started, CancellationToken ct)
    {
        await using var lease = started.Lease;
        try
        {
            await using var scope = scopes.CreateAsyncScope();
            await scope.ServiceProvider.GetRequiredService<ReconciliationRunner>().RunAsync(started.Run, ct);
        }
        catch (Exception ex)
        {
            // The runner records a failed run itself; this is for what it could not (the database is gone). The next run
            // marks the record Başarısız.
            logger.LogError("Reconciliation run could not be closed run={RunId}: {Message}", started.Run.Id, ex.Message);
        }
    }
}
