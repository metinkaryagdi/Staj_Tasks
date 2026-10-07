using InvoiceService.Application.Abstractions;
using InvoiceService.Domain.Reconciliation;

namespace InvoiceService.Application.Reconciliation;

/// <summary>Reads the runs and what they found.</summary>
public sealed class ReconciliationQueries(IReconciliationStore store)
{
    public const int DefaultPageSize = 20;

    /// <summary>A chosen limit: one page is one response, and a screen shows a few dozen runs at most.</summary>
    public const int MaxPageSize = 50;

    /// <summary>One page, newest first, without findings; and how many runs there are.</summary>
    public Task<(IReadOnlyList<ReconciliationRun> Items, int TotalCount)> ListRunsAsync(int page, int pageSize, CancellationToken ct) =>
        store.ListRunsPageAsync((page - 1) * pageSize, pageSize, ct);

    /// <summary>The run with its findings in the order they were found; null if there is no such run.</summary>
    public async Task<(ReconciliationRun Run, IReadOnlyList<ReconciliationFinding> Findings)?> FindRunAsync(long id, CancellationToken ct)
    {
        var run = await store.FindRunAsync(id, ct);
        return run is null ? null : (run, await store.ListFindingsAsync(id, ct));
    }
}
