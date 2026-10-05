using InvoiceService.Application.Webhooks;
using InvoiceService.Domain.Webhooks;

namespace InvoiceService.Application.Abstractions;

/// <summary>Storage of the events the ERP reported (the erp_webhook_events table).</summary>
public interface IWebhookEventStore
{
    /// <summary>
    /// Limits for the open transaction only: waiting longer than <paramref name="lockTimeoutMilliseconds"/> for a row lock,
    /// or running a statement longer than <paramref name="statementTimeoutMilliseconds"/>, fails it on the database server.
    /// </summary>
    Task LimitWaitsAsync(int lockTimeoutMilliseconds, int statementTimeoutMilliseconds, CancellationToken ct);

    /// <summary>
    /// Stores the event once: true when this call inserted it, false when it was already there (only delivery_count grows).
    /// </summary>
    Task<bool> InsertOrCountAsync(ErpWebhookRequest request, string payload, DateTimeOffset now, CancellationToken ct);

    /// <summary>Not tracked; the event must exist.</summary>
    Task<ErpWebhookEvent> GetAsync(string eventId, CancellationToken ct);

    /// <summary>Tracked: changes are written by <see cref="IUnitOfWork.SaveChangesAsync"/>; the event must exist.</summary>
    Task<ErpWebhookEvent> GetTrackedAsync(string eventId, CancellationToken ct);

    /// <summary>
    /// The invoice's waiting (Bekliyor) events, tracked and locked (FOR UPDATE), in the order they reached the service
    /// (received_at, then occurred_at).
    /// </summary>
    Task<IReadOnlyList<ErpWebhookEvent>> LockWaitingAsync(string invoiceNumber, CancellationToken ct);

    /// <summary>
    /// Makes a waiting event Yok Sayıldı (Fatura Yok), but only while it is still Bekliyor and the invoice is still not in
    /// the service. One statement, so an invoice or a repeat of the event arriving at the same time cannot interleave.
    /// </summary>
    Task<bool> IgnoreUnknownInvoiceAsync(string eventId, CancellationToken ct);
}
