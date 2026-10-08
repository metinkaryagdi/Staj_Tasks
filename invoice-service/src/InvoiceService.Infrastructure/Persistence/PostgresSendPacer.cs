using InvoiceService.Application.Abstractions;
using InvoiceService.Application.Outbox;
using Microsoft.EntityFrameworkCore;

namespace InvoiceService.Infrastructure.Persistence;

/// <summary>
/// Turns live in one row (erp_send_pace): one UPDATE takes a turn and moves the next on by 1/SendsPerSecond, using the
/// database clock, so two copies never take the same turn.
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
