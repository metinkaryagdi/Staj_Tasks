using InvoiceService.Application.Abstractions;

namespace InvoiceService.Application.Webhooks;

/// <summary>The outcome of one delivery: the event's status after it, and whether it was a repeat of a stored event.</summary>
public sealed record EventResult(string EventId, string Status, bool Repeat);

/// <summary>
/// Stores ERP events and applies them to invoices. Scoped: uses the request's (or the outbox send's) unit of work.
/// <para>
/// Every decision about an invoice is made while holding that invoice's row lock (SELECT ... FOR UPDATE), and the outbox
/// takes the same lock when it makes the invoice Gönderildi (its UPDATE). So "the invoice is not Gönderildi yet, the
/// event waits" and "the invoice is now Gönderildi, apply what is waiting" cannot interleave: whichever comes second
/// sees what the first committed.
/// </para>
/// </summary>
public sealed class WebhookEventProcessor(
    IUnitOfWork unitOfWork, IWebhookEventStore events, IInvoiceStore invoices, InvoiceEventApplier applier,
    TimeProvider time, IOptions<WebhookOptions> options, ILogger<WebhookEventProcessor> logger)
{
    /// <summary>
    /// Stores the event once and applies it, in one transaction. A repeated event_id only increments delivery_count.
    /// <para>
    /// The insert is INSERT ... ON CONFLICT (event_id) DO UPDATE: when the same event arrives several times at once,
    /// PostgreSQL lets one insert the row and makes the others wait for its row lock; they then find the row and only
    /// increment the counter (RETURNING xmax = 0 tells which case it was). Only the one that inserted applies the event.
    /// </para>
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
    /// Applies the invoice's waiting (Bekliyor) events in the order they reached the service (received_at). Called by
    /// the outbox in the same transaction that made the invoice Gönderildi, after that UPDATE (which holds the
    /// invoice's row lock). Arrival order, not occurred_at: an event is then treated the same whether the invoice was
    /// already Gönderildi when it arrived or not (e.g. a decision that arrived before invoice.received still makes the
    /// later invoice.received Yok Sayıldı).
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

    /// <summary>
    /// PostgreSQL's own limits for this transaction only: waiting longer than LockTimeoutMilliseconds for a
    /// row lock, or running a statement longer than ResponseBudgetMilliseconds, fails it on the server, so the event
    /// gets 503 in time even if cancelling from the client side would be slow.
    /// </summary>
    private Task LimitWaitsAsync(CancellationToken ct)
    {
        var settings = options.Value;
        return events.LimitWaitsAsync(settings.LockTimeoutMilliseconds, settings.ResponseBudgetMilliseconds, ct);
    }
}
