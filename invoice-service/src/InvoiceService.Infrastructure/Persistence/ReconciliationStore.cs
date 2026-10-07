using InvoiceService.Application.Abstractions;
using InvoiceService.Domain.Invoices;
using InvoiceService.Domain.Reconciliation;
using InvoiceService.Domain.Webhooks;
using Microsoft.EntityFrameworkCore;

namespace InvoiceService.Infrastructure.Persistence;

public sealed class ReconciliationStore(InvoiceDbContext db) : IReconciliationStore
{
    private const string AbandonedError = "Servis durdu: çalışma sonuçlanmadan kesildi.";

    public async Task<ReconciliationRun> StartRunAsync(DateTimeOffset now, string startedBy, CancellationToken ct)
    {
        var run = new ReconciliationRun { StartedAt = now, Status = ReconciliationStatus.Running, StartedBy = startedBy };
        db.ReconciliationRuns.Add(run);
        await db.SaveChangesAsync(ct);
        return run;
    }

    public async Task<int> FailAbandonedRunsAsync(DateTimeOffset now, CancellationToken ct) =>
        await db.Database.ExecuteSqlAsync($"""
            UPDATE reconciliation_runs r
            SET status = {ReconciliationStatus.Failed}, finished_at = {now}, error = {AbandonedError},
                fixed_count = (SELECT count(*) FROM reconciliation_findings f WHERE f.run_id = r.id AND f.action = {FindingAction.Fixed}),
                reported_count = (SELECT count(*) FROM reconciliation_findings f WHERE f.run_id = r.id AND f.action = {FindingAction.Reported})
            WHERE r.status = {ReconciliationStatus.Running}
            """, ct);

    public async Task FinishRunAsync(
        long id, string status, int checkedCount, int fixedCount, int reportedCount, string? error, DateTimeOffset now,
        CancellationToken ct) =>
        await db.ReconciliationRuns
            .Where(r => r.Id == id && r.Status == ReconciliationStatus.Running)
            .ExecuteUpdateAsync(s => s
                .SetProperty(r => r.Status, status)
                .SetProperty(r => r.FinishedAt, now)
                .SetProperty(r => r.CheckedCount, checkedCount)
                .SetProperty(r => r.FixedCount, fixedCount)
                .SetProperty(r => r.ReportedCount, reportedCount)
                .SetProperty(r => r.Error, error), ct);

    public void AddFinding(ReconciliationFinding finding) => db.ReconciliationFindings.Add(finding);

    public async Task<IReadOnlyList<ReconciliationRun>> ListRunsAsync(CancellationToken ct) =>
        await db.ReconciliationRuns.AsNoTracking().OrderByDescending(r => r.Id).ToListAsync(ct);

    public Task<ReconciliationRun?> FindRunAsync(long id, CancellationToken ct) =>
        db.ReconciliationRuns.AsNoTracking().SingleOrDefaultAsync(r => r.Id == id, ct);

    public async Task<IReadOnlyList<ReconciliationFinding>> ListFindingsAsync(long runId, CancellationToken ct) =>
        await db.ReconciliationFindings.AsNoTracking().Where(f => f.RunId == runId).OrderBy(f => f.Id).ToListAsync(ct);

    public async Task<IReadOnlyList<ReconciliationFinding>> ListFindingsOfInvoiceAsync(string invoiceNumber, CancellationToken ct) =>
        await db.ReconciliationFindings.AsNoTracking()
            .Where(f => f.InvoiceNumber == invoiceNumber)
            .OrderByDescending(f => f.Id)
            .ToListAsync(ct);

    public async Task<IReadOnlyList<Invoice>> InvoicesToCheckAsync(DateTimeOffset since, CancellationToken ct) =>
        await db.Invoices.AsNoTracking()
            .Where(i => i.CreatedAt >= since || InvoiceStatus.Unsettled.Contains(i.Status))
            .ToListAsync(ct);

    public async Task<IReadOnlyList<Invoice>> InvoicesByNumberAsync(IReadOnlyCollection<string> numbers, CancellationToken ct) =>
        await db.Invoices.AsNoTracking().Where(i => numbers.Contains(i.InvoiceNumber)).ToListAsync(ct);

    public async Task<IReadOnlyList<ErpWebhookEvent>> WaitingEventsOfUnknownInvoicesAsync(CancellationToken ct) =>
        await db.ErpWebhookEvents.AsNoTracking()
            .Where(e => e.Status == WebhookEventStatus.Pending && !db.Invoices.Any(i => i.InvoiceNumber == e.InvoiceNumber))
            .OrderBy(e => e.ReceivedAt)
            .ToListAsync(ct);
}
