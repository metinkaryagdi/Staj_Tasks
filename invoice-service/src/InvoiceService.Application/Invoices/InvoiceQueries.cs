using InvoiceService.Application.Abstractions;
using InvoiceService.Domain.Invoices;

namespace InvoiceService.Application.Invoices;

/// <summary>Reads invoices as stored by the service.</summary>
public sealed class InvoiceQueries(IInvoiceStore invoices)
{
    /// <summary>Ordered by invoice number; every invoice when <paramref name="status"/> is null.</summary>
    public Task<IReadOnlyList<Invoice>> ListAsync(string? status, CancellationToken ct) => invoices.ListAsync(status, ct);

    /// <summary>Null if there is no such invoice.</summary>
    public Task<Invoice?> FindAsync(string invoiceNumber, CancellationToken ct) => invoices.FindAsync(invoiceNumber, ct);
}
