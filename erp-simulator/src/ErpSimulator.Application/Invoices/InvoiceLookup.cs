using ErpSimulator.Application.Abstractions;
using ErpSimulator.Domain.Invoices;

namespace ErpSimulator.Application.Invoices;

/// <summary>Reads the ERP's records of an invoice number. No faults are injected here.</summary>
public sealed class InvoiceLookup(IErpInvoiceStore invoices)
{
    /// <summary>Oldest first; empty if the invoice number has no record.</summary>
    public Task<IReadOnlyList<ErpInvoice>> RecordsAsync(string invoiceNumber, CancellationToken ct) =>
        invoices.ListAsync(invoiceNumber, ct);
}
