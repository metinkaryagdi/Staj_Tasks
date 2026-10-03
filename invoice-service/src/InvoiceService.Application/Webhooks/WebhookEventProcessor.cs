using InvoiceService.Application.Abstractions;

namespace InvoiceService.Application.Webhooks;

/// <summary>The outcome of one delivery: the event's status after it, and whether it was a repeat of a stored event.</summary>
public sealed record EventResult(string EventId, string Status, bool Repeat);

/// <summary>
/// Stores ERP events and applies them to invoices. Every decision is made while holding the invoice's row lock, the same
/// lock the outbox takes when it makes the invoice Gönderildi, so the two can never interleave.
/// </summary>
public sealed class WebhookEventProcessor(
    IUnitOfWork unitOfWork, IWebhookEventStore events, IInvoiceStore invoices, InvoiceEventApplier applier,
    TimeProvider time, IOptions<WebhookOptions> options, ILogger<WebhookEventProcessor> logger)
{
    /// <summary>
    /// Stores the event once and applies it, in one transaction. A repeated event_id (even arriving at the same moment) is
    /// only counted, never applied again.
    /// </summary>
    public async Task<EventResult> ReceiveAsync(ErpWebhookRequest request, string payload, CancellationToken ct)
    {
        var now = time.GetUtcNow();
        await using var transaction = await unitOfWork.BeginAsync(ct);
        await LimitWaitsAsync(ct);

        var inserted = await events.InsertOrCountAsync(request, payload, now, ct);

        if (!inserted)
        {
            var stored = await events.GetAsync(request.EventId!, ct);
            await transaction.CommitAsync(ct);
            logger.LogInformation(
                "ERP webhook repeat event={EventId} type={EventType} invoice={InvoiceNumber} deliveries={Deliveries} " +
                "status={Status}: not applied again",
                stored.EventId, stored.EventType, stored.InvoiceNumber, stored.DeliveryCount, stored.Status);
            return new EventResult(stored.EventId, stored.Status, Repeat: true);
        }

        var ev = await events.GetTrackedAsync(request.EventId!, ct);
        var invoice = await invoices.LockAsync(ev.InvoiceNumber, ct);
        if (invoice is null)
        {
            logger.LogInformation(
                "ERP webhook stored event={EventId} type={EventType} invoice={InvoiceNumber} status={Status} invoiceStatus=- " +
                "(invoice unknown here; waits for it)",
                ev.EventId, ev.EventType, ev.InvoiceNumber, ev.Status);
        }
        else
        {
            applier.Apply(invoice, ev, now, afterSend: false);
        }

        await unitOfWork.SaveChangesAsync(ct);
        await transaction.CommitAsync(ct);
        return new EventResult(ev.EventId, ev.Status, Repeat: false);
    }

    /// <summary>
    /// Applies the invoice's waiting events in arrival order. Called by the outbox in the transaction that makes the
    /// invoice Gönderildi.
    /// </summary>
    public async Task ApplyWaitingAsync(string invoiceNumber, DateTimeOffset sentAt, CancellationToken ct)
    {
        var invoice = await invoices.LockAsync(invoiceNumber, ct);
        if (invoice is null)
            return;

        var waiting = await events.LockWaitingAsync(invoiceNumber, ct);
        if (waiting.Count == 0)
            return;

        // The waiting events are applied in the transaction that made the invoice Gönderildi: same moment.
        foreach (var ev in waiting)
            applier.Apply(invoice, ev, sentAt, afterSend: true);
        await unitOfWork.SaveChangesAsync(ct);
    }

    /// <summary>Lets the database itself stop this transaction if a lock wait or a statement takes too long.</summary>
    private Task LimitWaitsAsync(CancellationToken ct)
    {
        var settings = options.Value;
        return events.LimitWaitsAsync(settings.LockTimeoutMilliseconds, settings.ResponseBudgetMilliseconds, ct);
    }
}
