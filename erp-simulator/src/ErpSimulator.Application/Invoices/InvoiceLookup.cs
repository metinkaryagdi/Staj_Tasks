using ErpSimulator.Application.Abstractions;
using ErpSimulator.Domain.Invoices;

namespace ErpSimulator.Application.Invoices;

/// <param name="Records">Oldest first; empty if the invoice number has no record.</param>
/// <param name="Decision">Of the first record; <see cref="InvoiceDecision.None"/> when there is no record.</param>
public sealed record InvoiceLookupResult(IReadOnlyList<ErpInvoice> Records, InvoiceDecision Decision);

/// <summary>Reads the ERP's records of an invoice number and its decision. No faults are injected here.</summary>
public sealed class InvoiceLookup(IErpInvoiceStore invoices, IWebhookDeliveryStore deliveries, TimeProvider time)
{
    public async Task<InvoiceLookupResult> FindAsync(string invoiceNumber, CancellationToken ct)
    {
        var records = await invoices.ListAsync(invoiceNumber, ct);
        if (records.Count == 0)
            return new InvoiceLookupResult(records, InvoiceDecision.None);

        var planned = await deliveries.ListForInvoiceAsync(records[0].Id, ct);
        return new InvoiceLookupResult(records, InvoiceDecisions.Resolve(planned, time.GetUtcNow()));
    }
}
