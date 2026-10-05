using ErpSimulator.Domain.Invoices;
using ErpSimulator.Domain.Webhooks;

namespace ErpSimulator.Application.Abstractions;

/// <param name="Items">The requested page.</param>
/// <param name="TotalCount">All records in the range, not only this page.</param>
public sealed record InvoicePage(IReadOnlyList<ErpInvoice> Items, int TotalCount);

/// <summary>Storage of the ERP's invoice records (the invoices table).</summary>
public interface IErpInvoiceStore
{
    /// <summary>Starts a transaction that holds a lock on the invoice number until it ends.</summary>
    Task<IUnitOfWorkTransaction> LockInvoiceNumberAsync(string invoiceNumber);

    /// <summary>The first (oldest) record of the invoice number, not tracked; null if there is none.</summary>
    Task<ErpInvoice?> FindFirstAsync(string invoiceNumber);

    /// <summary>All records of the invoice number, oldest first, not tracked.</summary>
    Task<IReadOnlyList<ErpInvoice>> ListAsync(string invoiceNumber, CancellationToken ct);

    /// <summary>
    /// Saves the record and the events <paramref name="planEvents"/> plans for it in one transaction (the lock's, if
    /// open). Not cancellable: once the ERP decides to save, a client disconnect must not undo it.
    /// </summary>
    Task SaveAsync(ErpInvoice invoice, Func<ErpInvoice, IEnumerable<WebhookDelivery>> planEvents);

    /// <summary>
    /// The records received in [<paramref name="from"/>, <paramref name="to"/>), ordered by received_at then id (so a
    /// page does not change while records are added later), not tracked.
    /// </summary>
    Task<InvoicePage> ListReceivedAsync(DateTimeOffset from, DateTimeOffset to, int skip, int take, CancellationToken ct);
}
