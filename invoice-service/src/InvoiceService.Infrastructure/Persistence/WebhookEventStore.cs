using System.Globalization;
using InvoiceService.Application.Abstractions;
using InvoiceService.Application.Webhooks;
using InvoiceService.Domain.Webhooks;
using Microsoft.EntityFrameworkCore;

namespace InvoiceService.Infrastructure.Persistence;

public sealed class WebhookEventStore(InvoiceDbContext db) : IWebhookEventStore
{
    public async Task LimitWaitsAsync(int lockTimeoutMilliseconds, int statementTimeoutMilliseconds, CancellationToken ct)
    {
        var lockTimeout = lockTimeoutMilliseconds.ToString(CultureInfo.InvariantCulture);
        var statementTimeout = statementTimeoutMilliseconds.ToString(CultureInfo.InvariantCulture);
        // SET takes no parameters; both values are validated integers (milliseconds).
        var sql = "SET LOCAL lock_timeout = " + lockTimeout + "; SET LOCAL statement_timeout = " + statementTimeout;
        await db.Database.ExecuteSqlRawAsync(sql, ct);
    }

    public async Task<bool> InsertOrCountAsync(ErpWebhookRequest request, string payload, DateTimeOffset now, CancellationToken ct) =>
        (await db.Database.SqlQuery<bool>($"""
            INSERT INTO erp_webhook_events
                (event_id, event_type, invoice_number, erp_reference, occurred_at, received_at, status, payload, delivery_count)
            VALUES ({request.EventId}, {request.EventType}, {request.InvoiceNumber}, {request.ErpReference},
                    {request.OccurredAt!.Value}, {now}, {WebhookEventStatus.Pending}, {payload}, 1)
            ON CONFLICT (event_id) DO UPDATE SET delivery_count = erp_webhook_events.delivery_count + 1
            RETURNING (xmax = 0) AS "Value"
            """).ToListAsync(ct)).Single();

    public async Task<IReadOnlyList<ErpWebhookEvent>> ListByInvoiceAsync(string invoiceNumber, CancellationToken ct) =>
        await db.ErpWebhookEvents.AsNoTracking()
            .Where(e => e.InvoiceNumber == invoiceNumber)
            .OrderBy(e => e.ReceivedAt).ThenBy(e => e.OccurredAt)
            .ToListAsync(ct);

    public Task<ErpWebhookEvent> GetAsync(string eventId, CancellationToken ct) =>
        db.ErpWebhookEvents.AsNoTracking().SingleAsync(e => e.EventId == eventId, ct);

    public Task<ErpWebhookEvent> GetTrackedAsync(string eventId, CancellationToken ct) =>
        db.ErpWebhookEvents.SingleAsync(e => e.EventId == eventId, ct);

    public async Task<IReadOnlyList<ErpWebhookEvent>> LockWaitingAsync(string invoiceNumber, CancellationToken ct) =>
        await db.ErpWebhookEvents
            .FromSql($"""
                SELECT * FROM erp_webhook_events
                WHERE invoice_number = {invoiceNumber} AND status = {WebhookEventStatus.Pending}
                ORDER BY received_at, occurred_at
                FOR UPDATE
                """)
            .ToListAsync(ct);

    public async Task<bool> IgnoreUnknownInvoiceAsync(string eventId, CancellationToken ct) =>
        await db.Database.ExecuteSqlAsync($"""
            UPDATE erp_webhook_events e
            SET status = {WebhookEventStatus.Ignored}, ignore_reason = {IgnoreReason.UnknownInvoice}
            WHERE e.event_id = {eventId} AND e.status = {WebhookEventStatus.Pending}
              AND NOT EXISTS (SELECT 1 FROM invoices i WHERE i.invoice_number = e.invoice_number)
            """, ct) == 1;
}
