using InvoiceService.Domain.Invoices;
using InvoiceService.Domain.Outbox;
using InvoiceService.Domain.Reconciliation;
using InvoiceService.Domain.Webhooks;

namespace InvoiceService.Application.Invoices;

/// <summary>One page of the invoice list; <paramref name="TotalCount"/> counts every invoice the filters match.</summary>
public sealed record InvoicePage(IReadOnlyList<Invoice> Items, int TotalCount);

public sealed record StatusCount(string Status, int Count);

/// <param name="Counts">Every status, in <see cref="InvoiceStatus.All"/> order, with 0 for an empty one.</param>
/// <param name="StuckAfterMinutes">The wait after which a Gönderildi or İşleme Alındı invoice counts as stuck.</param>
public sealed record InvoiceSummary(IReadOnlyList<StatusCount> Counts, int Total, int StuckCount, int StuckAfterMinutes);

/// <summary>An invoice with everything the service keeps about it.</summary>
/// <param name="Outbox">Null for an invoice that has no erp_outbox entry.</param>
/// <param name="Events">In the order they reached the service.</param>
/// <param name="Findings">From every reconciliation run, newest first.</param>
public sealed record InvoiceDetails(
    Invoice Invoice, ErpOutboxEntry? Outbox, IReadOnlyList<ErpWebhookEvent> Events, IReadOnlyList<ReconciliationFinding> Findings);
