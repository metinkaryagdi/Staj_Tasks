using InvoiceService.Application.Abstractions;
using InvoiceService.Application.Outbox;
using InvoiceService.Domain.Outbox;
using Microsoft.EntityFrameworkCore;

namespace InvoiceService.Infrastructure.Persistence;

public sealed class OutboxStore(InvoiceDbContext db) : IOutboxStore
{
    public async Task<IReadOnlyList<ClaimedEntry>> ClaimAsync(
        int limit, string workerId, DateTimeOffset now, DateTimeOffset lockedUntil, int maxAttempts, CancellationToken ct) =>
        await db.Database.SqlQuery<ClaimedEntry>($"""
            WITH due AS (
                SELECT id, attempt_count FROM erp_outbox
                WHERE status = {OutboxStatus.Pending}
                  AND next_attempt_at <= {now}
                  AND (locked_until IS NULL OR locked_until < {now})
                ORDER BY next_attempt_at, id
                LIMIT {limit}
                FOR UPDATE SKIP LOCKED
            ), claimed AS (
                UPDATE erp_outbox o
                SET attempt_count = LEAST(o.attempt_count + 1, {maxAttempts}),
                    locked_until = {lockedUntil},
                    locked_by = {workerId},
                    claim_token = gen_random_uuid()
                FROM due d
                WHERE o.id = d.id
                RETURNING o.id, o.invoice_number, o.attempt_count, d.attempt_count >= {maxAttempts} AS used_up, o.claim_token
            ), counted AS (
                UPDATE invoices i
                SET send_attempt_count = i.send_attempt_count + 1, updated_at = {now}
                FROM claimed c
                WHERE i.invoice_number = c.invoice_number AND NOT c.used_up
            )
            SELECT id AS "Id", invoice_number AS "InvoiceNumber", attempt_count AS "Attempt", used_up AS "AttemptsUsedUp",
                   claim_token AS "ClaimToken"
            FROM claimed
            """).ToListAsync(ct);

    public Task<bool> IsHeldAsync(long id, Guid claimToken, DateTimeOffset now, CancellationToken ct) =>
        db.ErpOutbox.AsNoTracking().AnyAsync(
            o => o.Id == id && o.ClaimToken == claimToken && o.LockedUntil > now, ct);

    public async Task<bool> WriteOutcomeAsync(
        long id, Guid claimToken, string status, string? lastError, DateTimeOffset nextAttemptAt, DateTimeOffset? processedAt,
        CancellationToken ct)
    {
        var owned = await db.ErpOutbox
            .Where(o => o.Id == id && o.Status == OutboxStatus.Pending && o.ClaimToken == claimToken)
            .ExecuteUpdateAsync(s => s
                .SetProperty(o => o.Status, status)
                .SetProperty(o => o.LastError, lastError)
                .SetProperty(o => o.NextAttemptAt, nextAttemptAt)
                .SetProperty(o => o.ProcessedAt, processedAt)
                .SetProperty(o => o.LockedUntil, (DateTimeOffset?)null)
                .SetProperty(o => o.LockedBy, (string?)null)
                .SetProperty(o => o.ClaimToken, (Guid?)null), ct);
        return owned == 1;
    }

    public async Task ResetAsync(string invoiceNumber, DateTimeOffset now, CancellationToken ct) =>
        await db.Database.ExecuteSqlAsync($"""
            INSERT INTO erp_outbox (invoice_number, status, attempt_count, next_attempt_at, created_at)
            VALUES ({invoiceNumber}, {OutboxStatus.Pending}, 0, {now}, {now})
            ON CONFLICT (invoice_number) DO UPDATE
            SET status = EXCLUDED.status,
                attempt_count = 0,
                next_attempt_at = EXCLUDED.next_attempt_at,
                last_error = NULL,
                processed_at = NULL,
                locked_until = NULL,
                locked_by = NULL,
                claim_token = NULL
            """, ct);

    public async Task CompleteFailedAsync(string invoiceNumber, DateTimeOffset now, CancellationToken ct) =>
        await db.ErpOutbox
            .Where(o => o.InvoiceNumber == invoiceNumber && o.Status == OutboxStatus.Failed)
            .ExecuteUpdateAsync(s => s
                .SetProperty(o => o.Status, OutboxStatus.Completed)
                .SetProperty(o => o.LastError, (string?)null)
                .SetProperty(o => o.ProcessedAt, now), ct);
}
