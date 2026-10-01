using InvoiceService.Data;
using InvoiceService.Erp;
using Microsoft.EntityFrameworkCore;

namespace InvoiceService.Outbox;

/// <summary>A queued send the worker has taken: <see cref="Attempt"/> is this attempt's number (already counted).</summary>
public sealed record ClaimedEntry(long Id, string InvoiceNumber, int Attempt);

/// <summary>
/// Takes due entries from erp_outbox and sends them. Scoped: one instance (and one DbContext) per claim or per send.
/// </summary>
public sealed class OutboxProcessor(InvoiceDbContext db, ErpClient erp, TimeProvider time, ILogger<OutboxProcessor> logger)
{
    /// <summary>
    /// How long a taken entry belongs to the worker that took it. Much longer than one send (10 s timeout), so it never
    /// runs out during a normal send; if the service is killed mid-send, another worker takes the entry after this time.
    /// </summary>
    public static readonly TimeSpan LockDuration = TimeSpan.FromSeconds(60);

    /// <summary>
    /// Takes up to <paramref name="limit"/> pending entries whose time has come and that nobody holds. In one statement:
    /// FOR UPDATE SKIP LOCKED lets two instances run this at the same time without taking the same row (each skips the
    /// rows the other is taking), locked_until/locked_by mark the row as taken after the statement ends, and the attempt
    /// is counted before the send, so a send cut off by a crash is still counted.
    /// </summary>
    public async Task<IReadOnlyList<ClaimedEntry>> ClaimAsync(int limit, string workerId, CancellationToken ct)
    {
        var now = time.GetUtcNow();
        var lockedUntil = now + LockDuration;

        return await db.Database.SqlQuery<ClaimedEntry>($"""
            WITH claimed AS (
                UPDATE erp_outbox
                SET attempt_count = attempt_count + 1,
                    locked_until = {lockedUntil},
                    locked_by = {workerId}
                WHERE id IN (
                    SELECT id FROM erp_outbox
                    WHERE status = {OutboxStatus.Pending}
                      AND next_attempt_at <= {now}
                      AND (locked_until IS NULL OR locked_until < {now})
                    ORDER BY next_attempt_at, id
                    LIMIT {limit}
                    FOR UPDATE SKIP LOCKED)
                RETURNING id, invoice_number, attempt_count
            ), counted AS (
                UPDATE invoices i
                SET send_attempt_count = i.send_attempt_count + 1, updated_at = {now}
                FROM claimed c
                WHERE i.invoice_number = c.invoice_number
            )
            SELECT id AS "Id", invoice_number AS "InvoiceNumber", attempt_count AS "Attempt" FROM claimed
            """).ToListAsync(ct);
    }

    /// <summary>
    /// Sends one taken entry and writes the outcome to erp_outbox and invoices in one transaction.
    /// For now a single attempt: 202 -> Gönderildi / Tamamlandı, anything else -> Başarısız on both.
    /// </summary>
    public async Task SendAsync(ClaimedEntry entry, string workerId)
    {
        // CancellationToken.None: once the ERP is called, the outcome must be recorded even while the service stops.
        var invoice = await db.Invoices.AsNoTracking().SingleAsync(i => i.InvoiceNumber == entry.InvoiceNumber, CancellationToken.None);
        var result = await erp.SendAsync(invoice, CancellationToken.None);

        var now = time.GetUtcNow();
        var invoiceStatus = result.Accepted ? InvoiceStatus.Sent : InvoiceStatus.Failed;
        var outboxStatus = result.Accepted ? OutboxStatus.Completed : OutboxStatus.Failed;

        await using var transaction = await db.Database.BeginTransactionAsync(CancellationToken.None);

        // Written only if this worker still holds this attempt. If the lock ran out and another worker took the entry
        // (attempt_count moved on), this older outcome is dropped instead of overwriting the newer attempt.
        var owned = await db.ErpOutbox
            .Where(o => o.Id == entry.Id && o.Status == OutboxStatus.Pending && o.AttemptCount == entry.Attempt && o.LockedBy == workerId)
            .ExecuteUpdateAsync(s => s
                .SetProperty(o => o.Status, outboxStatus)
                .SetProperty(o => o.LastError, result.Error)
                .SetProperty(o => o.ProcessedAt, now)
                .SetProperty(o => o.LockedUntil, (DateTimeOffset?)null)
                .SetProperty(o => o.LockedBy, (string?)null), CancellationToken.None);

        if (owned == 1)
        {
            await db.Invoices
                .Where(i => i.InvoiceNumber == entry.InvoiceNumber)
                .ExecuteUpdateAsync(s => s
                    .SetProperty(i => i.Status, invoiceStatus)
                    .SetProperty(i => i.ErpReference, result.ErpReference)
                    .SetProperty(i => i.LastError, result.Error)
                    .SetProperty(i => i.UpdatedAt, now), CancellationToken.None);
            await transaction.CommitAsync(CancellationToken.None);
        }

        logger.LogInformation(
            "ERP send invoice={InvoiceNumber} attempt={Attempt} worker={Worker} result={Status} http={HttpStatus} " +
            "erpReference={ErpReference} elapsed={ElapsedMs}ms error={Error}{NotWritten}",
            entry.InvoiceNumber, entry.Attempt, workerId, invoiceStatus, result.HttpStatus?.ToString() ?? "-",
            result.ErpReference ?? "-", (long)result.Elapsed.TotalMilliseconds, result.Error ?? "-",
            owned == 1 ? "" : " (not written: the entry is no longer held by this worker)");
    }
}
