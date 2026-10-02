using InvoiceService.Data;
using Microsoft.EntityFrameworkCore;

namespace InvoiceService.Webhooks;

/// <summary>The outcome of one delivery: the event's status after it, and whether it was a repeat of a stored event.</summary>
public sealed record EventResult(string EventId, string Status, bool Repeat);

/// <summary>
/// Stores ERP events and applies them to invoices. Scoped: uses the request's (or the outbox send's) DbContext.
/// <para>
/// Every decision about an invoice is made while holding that invoice's row lock (SELECT ... FOR UPDATE), and the outbox
/// takes the same lock when it makes the invoice Gönderildi (its UPDATE). So "the invoice is not Gönderildi yet, the
/// event waits" and "the invoice is now Gönderildi, apply what is waiting" cannot interleave: whichever comes second
/// sees what the first committed.
/// </para>
/// </summary>
public sealed class WebhookEventProcessor(InvoiceDbContext db, TimeProvider time, ILogger<WebhookEventProcessor> logger)
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
        await using var transaction = await db.Database.BeginTransactionAsync(ct);

        var inserted = (await db.Database.SqlQuery<bool>($"""
            INSERT INTO erp_webhook_events
                (event_id, event_type, invoice_number, erp_reference, occurred_at, received_at, status, payload, delivery_count)
            VALUES ({request.EventId}, {request.EventType}, {request.InvoiceNumber}, {request.ErpReference},
                    {request.OccurredAt!.Value}, {now}, {WebhookEventStatus.Pending}, {payload}, 1)
            ON CONFLICT (event_id) DO UPDATE SET delivery_count = erp_webhook_events.delivery_count + 1
            RETURNING (xmax = 0) AS "Value"
            """).ToListAsync(ct)).Single();

        if (!inserted)
        {
            var stored = await db.ErpWebhookEvents.AsNoTracking().SingleAsync(e => e.EventId == request.EventId, ct);
            await transaction.CommitAsync(ct);
            logger.LogInformation(
                "ERP webhook repeat event={EventId} type={EventType} invoice={InvoiceNumber} deliveries={Deliveries} " +
                "status={Status}: not applied again",
                stored.EventId, stored.EventType, stored.InvoiceNumber, stored.DeliveryCount, stored.Status);
            return new EventResult(stored.EventId, stored.Status, Repeat: true);
        }

        var ev = await db.ErpWebhookEvents.SingleAsync(e => e.EventId == request.EventId, ct);
        var invoice = await LockInvoiceAsync(ev.InvoiceNumber, ct);
        if (invoice is null)
        {
            logger.LogInformation(
                "ERP webhook stored event={EventId} type={EventType} invoice={InvoiceNumber} status={Status} invoiceStatus=- " +
                "(invoice unknown here; waits for it)",
                ev.EventId, ev.EventType, ev.InvoiceNumber, ev.Status);
        }
        else
        {
            Apply(invoice, ev, now, afterSend: false);
        }

        await db.SaveChangesAsync(ct);
        await transaction.CommitAsync(ct);
        return new EventResult(ev.EventId, ev.Status, Repeat: false);
    }

    /// <summary>
    /// Applies the invoice's waiting (Bekliyor) events, oldest occurred_at first. Called by the outbox in the same
    /// transaction that made the invoice Gönderildi, after that UPDATE (which holds the invoice's row lock).
    /// </summary>
    public async Task ApplyWaitingAsync(string invoiceNumber, CancellationToken ct)
    {
        var invoice = await LockInvoiceAsync(invoiceNumber, ct);
        if (invoice is null)
            return;

        var waiting = await db.ErpWebhookEvents
            .FromSql($"""
                SELECT * FROM erp_webhook_events
                WHERE invoice_number = {invoiceNumber} AND status = {WebhookEventStatus.Pending}
                ORDER BY occurred_at, received_at
                FOR UPDATE
                """)
            .ToListAsync(ct);
        if (waiting.Count == 0)
            return;

        var now = time.GetUtcNow();
        foreach (var ev in waiting)
            Apply(invoice, ev, now, afterSend: true);
        await db.SaveChangesAsync(ct);
    }

    /// <summary>Tracked and locked until the transaction ends; null if there is no such invoice.</summary>
    private async Task<Invoice?> LockInvoiceAsync(string invoiceNumber, CancellationToken ct) =>
        (await db.Invoices
            .FromSql($"SELECT * FROM invoices WHERE invoice_number = {invoiceNumber} FOR UPDATE")
            .ToListAsync(ct))
        .SingleOrDefault();

    private void Apply(Invoice invoice, ErpWebhookEvent ev, DateTimeOffset now, bool afterSend)
    {
        var before = invoice.Status;
        var transition = InvoiceTransitions.For(invoice.Status, ev.EventType);

        // Only an invoice the ERP has (Gönderildi or later) has a reference to compare with.
        if (transition.Outcome != TransitionOutcome.Wait && ev.ErpReference != invoice.ErpReference)
            transition = new Transition(TransitionOutcome.Ignore, IgnoreReason: IgnoreReason.ReferenceMismatch);

        switch (transition.Outcome)
        {
            case TransitionOutcome.Apply:
                invoice.Status = transition.NewStatus!;
                if (ev.EventType == WebhookEventType.Rejected)
                    invoice.RejectReason = ReadReason(ev.Payload);
                invoice.UpdatedAt = now;
                ev.Status = WebhookEventStatus.Processed;
                ev.ProcessedAt = now;
                break;
            case TransitionOutcome.Ignore:
                ev.Status = WebhookEventStatus.Ignored;
                ev.IgnoreReason = transition.IgnoreReason;
                ev.ProcessedAt = now;
                break;
            case TransitionOutcome.Wait:
                ev.Status = WebhookEventStatus.Pending;
                break;
        }

        var message =
            "ERP webhook {Action} event={EventId} type={EventType} invoice={InvoiceNumber} status={Status} " +
            "invoiceStatus={Before}->{After} ignoreReason={IgnoreReason} eventErpReference={EventReference} " +
            "invoiceErpReference={InvoiceReference}";
        object?[] args =
        [
            afterSend ? "applied-after-send" : "stored", ev.EventId, ev.EventType, ev.InvoiceNumber, ev.Status,
            before, invoice.Status, ev.IgnoreReason ?? "-", ev.ErpReference, invoice.ErpReference ?? "-"
        ];
        // The task asks for a warning when the reference does not match.
        if (ev.IgnoreReason == IgnoreReason.ReferenceMismatch)
            logger.LogWarning(message, args);
        else
            logger.LogInformation(message, args);
    }

    /// <summary>The reason from the stored body (validated as present when the event arrived).</summary>
    private static string? ReadReason(string payload) =>
        System.Text.Json.JsonSerializer.Deserialize<ErpWebhookRequest>(payload, System.Text.Json.JsonSerializerOptions.Web)?.Reason;
}
