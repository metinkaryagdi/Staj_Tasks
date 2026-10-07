using InvoiceService.Application.Invoices;
using InvoiceService.Domain.Invoices;
using InvoiceService.Domain.Outbox;

namespace InvoiceService.Application.Abstractions;

/// <summary>Storage of invoices (the invoices table).</summary>
public interface IInvoiceStore
{
    /// <summary>Takes the next value from the sequence; numbers are never reused, even if the insert later
    /// fails.</summary>
    Task<string> NextInvoiceNumberAsync(CancellationToken ct);

    /// <summary>
    /// Saves the invoice and its outbox entry with one save: both rows are written or neither is. There is never an
    /// invoice that nobody will send, nor a send queued for an invoice that does not exist.
    /// </summary>
    Task QueueAsync(Invoice invoice, ErpOutboxEntry entry, CancellationToken ct);

    /// <summary>Not tracked; null if there is no such invoice.</summary>
    Task<Invoice?> FindAsync(string invoiceNumber, CancellationToken ct);

    /// <summary>Not tracked; the invoice must exist.</summary>
    Task<Invoice> GetAsync(string invoiceNumber, CancellationToken ct);

    /// <summary>
    /// One page, newest first, not tracked. <paramref name="status"/>, <paramref name="search"/> (part of the invoice
    /// number, any case) and <paramref name="stuckBefore"/> (only the invoices <see cref="CountStuckAsync"/> counts with
    /// that time) narrow the list when they are not null; the total counts every invoice they match.
    /// </summary>
    Task<InvoicePage> ListPageAsync(
        string? status, string? search, DateTimeOffset? stuckBefore, int skip, int take, CancellationToken ct);

    /// <summary>How many invoices are in each status; a status nobody is in is missing.</summary>
    Task<IReadOnlyDictionary<string, int>> CountByStatusAsync(CancellationToken ct);

    /// <summary>
    /// How many invoices are Gönderildi or İşleme Alındı and were last updated before <paramref name="olderThan"/>.
    /// </summary>
    Task<int> CountStuckAsync(DateTimeOffset olderThan, CancellationToken ct);

    /// <summary>
    /// Conditional: only a Başarısız invoice moves to Bekliyor (last_error cleared). Returns how many rows changed (0
    /// or 1), so two resends at the same time cannot both queue it.
    /// </summary>
    Task<int> MarkPendingIfFailedAsync(string invoiceNumber, DateTimeOffset now, CancellationToken ct);

    /// <summary>
    /// Writes the outcome of a send. The UPDATE takes the invoice's row lock, which is what makes "apply the waiting
    /// events" and "an event arrives" unable to interleave.
    /// </summary>
    Task WriteSendOutcomeAsync(
        string invoiceNumber, string status, string? erpReference, string? lastError, DateTimeOffset now, CancellationToken ct);

    /// <summary>
    /// Tracked and locked until the transaction ends (SELECT ... FOR UPDATE); null if there is no such invoice.
    /// </summary>
    Task<Invoice?> LockAsync(string invoiceNumber, CancellationToken ct);
}
