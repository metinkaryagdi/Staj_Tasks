using InvoiceService.Application.Reconciliation;
using InvoiceService.Domain.Invoices;
using InvoiceService.Domain.Reconciliation;
using InvoiceService.Domain.Webhooks;

namespace InvoiceService.Application.Abstractions;

/// <summary>Storage of the reconciliation runs and findings, and the reads a run makes of the service's own
/// data.</summary>
public interface IReconciliationStore
{
    /// <summary>Records a new run as Çalışıyor; <paramref name="startedBy"/>: the operator or
    /// <see cref="ReconciliationRun.Schedule"/>.</summary>
    Task<ReconciliationRun> StartRunAsync(DateTimeOffset now, string startedBy, CancellationToken ct);

    /// <summary>
    /// Makes every run still Çalışıyor Başarısız ("the service stopped") and counts its findings. Only called while the
    /// run lock is held, so a run still Çalışıyor then belongs to a service that is gone.
    /// </summary>
    Task<int> FailAbandonedRunsAsync(DateTimeOffset now, CancellationToken ct);

    /// <summary>Closes the run; <paramref name="error"/> only for Başarısız.</summary>
    Task FinishRunAsync(
        long id, string status, int checkedCount, int fixedCount, int reportedCount, string? error, DateTimeOffset now,
        CancellationToken ct);

    /// <summary>Adds a finding to the open unit of work; <see cref="IUnitOfWork.SaveChangesAsync"/> writes
    /// it.</summary>
    void AddFinding(ReconciliationFinding finding);

    /// <summary>One page of runs, newest first, without findings; and how many runs there are.</summary>
    Task<(IReadOnlyList<ReconciliationRun> Items, int TotalCount)> ListRunsPageAsync(int skip, int take, CancellationToken ct);

    Task<ReconciliationRun?> FindRunAsync(long id, CancellationToken ct);

    /// <summary>In the order they were found.</summary>
    Task<IReadOnlyList<ReconciliationFinding>> ListFindingsAsync(long runId, CancellationToken ct);

    /// <summary>The findings about this invoice from every run, newest first.</summary>
    Task<IReadOnlyList<ReconciliationFinding>> ListFindingsOfInvoiceAsync(string invoiceNumber, CancellationToken ct);

    /// <summary>
    /// Invoices created at or after <paramref name="since"/>, and every <see cref="InvoiceStatus.Unsettled"/> invoice
    /// however old, not tracked.
    /// </summary>
    Task<IReadOnlyList<Invoice>> InvoicesToCheckAsync(DateTimeOffset since, CancellationToken ct);

    /// <summary>The invoices with these numbers (the ones that exist), not tracked.</summary>
    Task<IReadOnlyList<Invoice>> InvoicesByNumberAsync(IReadOnlyCollection<string> numbers, CancellationToken ct);

    /// <summary>
    /// Writes on each invoice when the ERP was asked about it and what it answered (erp_checked_at, erp_check_result),
    /// leaving updated_at as it is.
    /// </summary>
    Task RecordErpChecksAsync(IReadOnlyList<ErpCheck> checks, DateTimeOffset at, CancellationToken ct);

    /// <summary>The Bekliyor events whose invoice number the service has no invoice for, not tracked.</summary>
    Task<IReadOnlyList<ErpWebhookEvent>> WaitingEventsOfUnknownInvoicesAsync(CancellationToken ct);
}
