using InvoiceService.Application.Abstractions;
using InvoiceService.Domain.Reconciliation;

namespace InvoiceService.Application.Reconciliation;

/// <summary>Reads the runs and what they found.</summary>
public sealed class ReconciliationQueries(IReconciliationStore store)
{
    /// <summary>Newest first, without findings.</summary>
    public Task<IReadOnlyList<ReconciliationRun>> ListRunsAsync(CancellationToken ct) => store.ListRunsAsync(ct);

    /// <summary>The run with its findings in the order they were found; null if there is no such run.</summary>
    public async Task<(ReconciliationRun Run, IReadOnlyList<ReconciliationFinding> Findings)?> FindRunAsync(long id, CancellationToken ct)
    {
        var run = await store.FindRunAsync(id, ct);
        return run is null ? null : (run, await store.ListFindingsAsync(id, ct));
    }
}
