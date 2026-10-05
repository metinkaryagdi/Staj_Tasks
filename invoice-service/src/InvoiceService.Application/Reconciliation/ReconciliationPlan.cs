using InvoiceService.Application.Abstractions;
using InvoiceService.Domain.Invoices;
using InvoiceService.Domain.Webhooks;

namespace InvoiceService.Application.Reconciliation;

/// <summary>Everything a run reads before it compares: the service's side and the ERP's side at about the same
/// time.</summary>
/// <param name="Invoices">The service's invoices in the window, plus the ones the ERP lists.</param>
/// <param name="ErpRecords">The ERP's records in the window, oldest first.</param>
/// <param name="UnknownInvoiceEvents">Waiting events whose invoice the service does not have at all.</param>
public sealed record ReconciliationSnapshot(
    DateTimeOffset Now,
    IReadOnlyList<Invoice> Invoices,
    IReadOnlyList<ErpRecord> ErpRecords,
    IReadOnlyList<ErpWebhookEvent> UnknownInvoiceEvents);

public enum FixKind
{
    /// <summary>A Gönderildi / İşleme Alındı invoice takes the ERP's decision (same rules as an event).</summary>
    ApplyDecision,

    /// <summary>A Başarısız invoice the ERP has becomes Gönderildi with the ERP's reference, then takes the
    /// decision.</summary>
    RecoverFailed,

    /// <summary>A waiting event for an unknown invoice becomes Yok Sayıldı.</summary>
    IgnoreEvent
}

/// <summary>
/// What a run changes, decided from the snapshot. The invoice is read again under its lock before anything is written
/// (<see cref="ExpectedStatus"/> must still be its status), so a change made in between wins.
/// </summary>
public sealed record Fix(
    FixKind Kind, string InvoiceNumber, string? ExpectedStatus = null, string? ErpReference = null,
    ErpDecision? Decision = null, string? EventId = null);

/// <summary>
/// A difference found. With a <see cref="Fix"/> it is written as Düzeltildi once fixed; without, as Raporlandı.
/// </summary>
/// <param name="Details">Worded as if the fix was done: it is only stored once it was.</param>
public sealed record PlannedFinding(string InvoiceNumber, string FindingType, string Details, Fix? Fix = null);

/// <param name="CheckedCount">Distinct invoice numbers compared.</param>
public sealed record ReconciliationPlan(int CheckedCount, IReadOnlyList<PlannedFinding> Findings);
