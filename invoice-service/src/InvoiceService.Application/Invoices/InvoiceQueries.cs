using InvoiceService.Application.Abstractions;
using InvoiceService.Application.Reconciliation;
using InvoiceService.Domain.Invoices;

namespace InvoiceService.Application.Invoices;

/// <summary>Reads invoices as stored by the service.</summary>
public sealed class InvoiceQueries(
    IInvoiceStore invoices, IOutboxStore outbox, IWebhookEventStore events, IReconciliationStore reconciliation,
    IOptions<ReconciliationOptions> reconciliationOptions, TimeProvider time)
{
    public const int DefaultPageSize = 20;

    /// <summary>A chosen limit: a page is one response, and the screen's bulk resend takes at most this many too.</summary>
    public const int MaxPageSize = 100;

    /// <summary>Newest first; <paramref name="search"/> is part of the invoice number.</summary>
    public Task<InvoicePage> ListAsync(string? status, string? search, int page, int pageSize, CancellationToken ct) =>
        invoices.ListPageAsync(status, string.IsNullOrWhiteSpace(search) ? null : search.Trim(), (page - 1) * pageSize, pageSize, ct);

    /// <summary>Null if there is no such invoice.</summary>
    public Task<Invoice?> FindAsync(string invoiceNumber, CancellationToken ct) => invoices.FindAsync(invoiceNumber, ct);

    public async Task<InvoiceSummary> SummaryAsync(CancellationToken ct)
    {
        var options = reconciliationOptions.Value;
        var byStatus = await invoices.CountByStatusAsync(ct);
        var stuck = await invoices.CountStuckAsync(time.GetUtcNow() - options.StuckAfter, ct);

        var counts = InvoiceStatus.All.Select(s => new StatusCount(s, byStatus.GetValueOrDefault(s))).ToList();
        return new InvoiceSummary(counts, counts.Sum(c => c.Count), stuck, options.StuckAfterMinutes);
    }

    /// <summary>Null if there is no such invoice.</summary>
    public async Task<InvoiceDetails?> DetailsAsync(string invoiceNumber, CancellationToken ct)
    {
        var invoice = await invoices.FindAsync(invoiceNumber, ct);
        if (invoice is null)
            return null;

        return new InvoiceDetails(
            invoice,
            await outbox.FindAsync(invoiceNumber, ct),
            await events.ListByInvoiceAsync(invoiceNumber, ct),
            await reconciliation.ListFindingsOfInvoiceAsync(invoiceNumber, ct));
    }
}
