using InvoiceService.Application.Abstractions;
using InvoiceService.Application.Outbox;
using Microsoft.EntityFrameworkCore;

namespace InvoiceService.Infrastructure.Persistence;

/// <summary>
/// The turns live in one row (erp_send_pace) of the database every copy uses: one UPDATE moves the next free turn on by
/// 1/SendsPerSecond and returns the one taken, so two copies can never take the same turn. The database clock is used
/// for both the turn and "now", so the copies' own clocks do not matter. A turn is never earlier than now: time without
/// sends is not saved up for a burst later.
/// </summary>
public sealed class PostgresSendPacer(InvoiceDbContext db, IOptions<OutboxOptions> options, TimeProvider time) : IErpSendPacer
{
    public async Task WaitForTurnAsync(CancellationToken ct)
    {
        var spacingSeconds = 1.0 / options.Value.SendsPerSecond;
        // ToListAsync, not SingleAsync: EF would wrap the UPDATE in a SELECT, which PostgreSQL does not allow.
        var waitMs = (await db.Database.SqlQuery<double>($"""
            UPDATE erp_send_pace
            SET next_turn_at = GREATEST(next_turn_at, clock_timestamp()) + make_interval(secs => {spacingSeconds})
            WHERE id = 1
            RETURNING (EXTRACT(EPOCH FROM next_turn_at - make_interval(secs => {spacingSeconds}) - clock_timestamp()) * 1000)::double precision AS "Value"
            """).ToListAsync(ct)).Single();

        if (waitMs > 0)
            await Task.Delay(TimeSpan.FromMilliseconds(waitMs), time, ct);
    }
}
