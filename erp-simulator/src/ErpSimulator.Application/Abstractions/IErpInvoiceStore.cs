using ErpSimulator.Domain.Invoices;
using ErpSimulator.Domain.Webhooks;

namespace ErpSimulator.Application.Abstractions;

/// <param name="Items">The requested page.</param>
/// <param name="TotalCount">All records in the range, not only this page.</param>
/// <param name="Cancellations">The cancellations of the page's invoice numbers, by invoice number.</param>
public sealed record InvoicePage(
    IReadOnlyList<ErpInvoice> Items, int TotalCount, IReadOnlyDictionary<string, ErpCancellation> Cancellations);

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

    /// <summary>The invoice number's cancellation, not tracked; null if it is not cancelled.</summary>
    Task<ErpCancellation?> FindCancellationAsync(string invoiceNumber, CancellationToken ct);

    /// <summary>
    /// In the invoice number lock's transaction, and commits it: saves the cancellation and <paramref name="events"/>, and
    /// makes every event of the invoice number planned for after the cancellation Skipped, so a cancelled invoice is not
    /// approved or rejected later. Not cancellable, like <see cref="SaveAsync"/>.
    /// </summary>
    Task SaveCancellationAsync(ErpCancellation cancellation, IReadOnlyList<WebhookDelivery> events);
}
