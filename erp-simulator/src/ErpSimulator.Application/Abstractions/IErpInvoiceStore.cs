using ErpSimulator.Domain.Invoices;
using ErpSimulator.Domain.Webhooks;

namespace ErpSimulator.Application.Abstractions;

/// <summary>Storage of the ERP's invoice records (the invoices table).</summary>
public interface IErpInvoiceStore
{
    /// <summary>
    /// Starts a transaction holding a lock on the invoice number until it ends (committed by <see cref="SaveAsync"/>,
    /// otherwise rolled back when disposed). A lock instead of a unique index: existing duplicates stay valid and the
    /// setting can be switched off again.
    /// </summary>
    Task<IUnitOfWorkTransaction> LockInvoiceNumberAsync(string invoiceNumber);

    /// <summary>The first (oldest) record of the invoice number, not tracked; null if there is none.</summary>
    Task<ErpInvoice?> FindFirstAsync(string invoiceNumber);

    /// <summary>All records of the invoice number, oldest first, not tracked.</summary>
    Task<IReadOnlyList<ErpInvoice>> ListAsync(string invoiceNumber, CancellationToken ct);

    /// <summary>
    /// Saves the record and its planned events in one transaction (the lock's transaction if one is open): a saved
    /// invoice always gets its events, and no event exists for an invoice that was not saved. The events need the ERP
    /// reference, which the database generates on insert, so the record is inserted first and then
    /// <paramref name="planEvents"/> is called with it. Not cancellable: once the ERP decides to save, a client
    /// disconnect must not undo it.
    /// </summary>
    Task SaveAsync(ErpInvoice invoice, Func<ErpInvoice, IEnumerable<WebhookDelivery>> planEvents);
}
