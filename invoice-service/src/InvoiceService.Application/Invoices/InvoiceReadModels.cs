using InvoiceService.Domain.Invoices;
using InvoiceService.Domain.Operators;
using InvoiceService.Domain.Outbox;
using InvoiceService.Domain.Reconciliation;
using InvoiceService.Domain.Webhooks;

namespace InvoiceService.Application.Invoices;

/// <summary>One page of the invoice list; <paramref name="TotalCount"/> counts every invoice the filters match.</summary>
public sealed record InvoicePage(IReadOnlyList<Invoice> Items, int TotalCount);

/// <summary>An invoice of the list with whether the summary counts it as stuck.</summary>
public sealed record ListedInvoice(Invoice Invoice, bool Stuck);

/// <summary>One page of the list as the screen gets it; <paramref name="TotalCount"/> counts every invoice the filters
/// match.</summary>
public sealed record InvoiceListPage(IReadOnlyList<ListedInvoice> Items, int TotalCount);

public sealed record StatusCount(string Status, int Count);

/// <param name="Counts">Every status, in <see cref="InvoiceStatus.All"/> order, with 0 for an empty one.</param>
/// <param name="StuckAfterMinutes">The wait after which a Gönderildi or İşleme Alındı invoice counts as stuck.</param>
public sealed record InvoiceSummary(IReadOnlyList<StatusCount> Counts, int Total, int StuckCount, int StuckAfterMinutes);

/// <summary>An invoice with everything the service keeps about it.</summary>
/// <param name="Outbox">Null for an invoice that has no erp_outbox entry.</param>
/// <param name="Events">In the order they reached the service.</param>
/// <param name="Findings">From every reconciliation run, newest first.</param>
/// <param name="OperatorActions">The interventions made on it from the screen, newest first.</param>
/// <param name="Stuck">Whether the summary counts it as stuck.</param>
public sealed record InvoiceDetails(
    Invoice Invoice, ErpOutboxEntry? Outbox, IReadOnlyList<ErpWebhookEvent> Events, IReadOnlyList<ReconciliationFinding> Findings,
    IReadOnlyList<OperatorAction> OperatorActions, bool Stuck);
