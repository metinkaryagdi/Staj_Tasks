using System.Globalization;
using InvoiceService.Data;
using InvoiceService.Erp;
using Microsoft.EntityFrameworkCore;
using Microsoft.Extensions.Options;

namespace InvoiceService.Outbox;

/// <summary>
/// A queued send the worker has taken: <see cref="Attempt"/> is this attempt's number (already counted).
/// <see cref="AttemptsUsedUp"/>: the entry had already used all its attempts when it was taken, i.e. the last attempt was
/// cut off (the service stopped before writing its outcome). Such an entry is not sent again; the ERP is only asked.
/// <see cref="ClaimToken"/>: the id of this taking (erp_outbox.claim_token); see <see cref="Data.ErpOutboxEntry.ClaimToken"/>.
/// </summary>
public sealed record ClaimedEntry(long Id, string InvoiceNumber, int Attempt, bool AttemptsUsedUp, Guid ClaimToken)
{
    /// <summary>Short form of the claim token for the log.</summary>
    public string Claim => ClaimToken.ToString("N")[..8];
}

/// <summary>
/// Takes due entries from erp_outbox and sends them. Scoped: one instance (and one DbContext) per claim or per send.
/// </summary>
public sealed class OutboxProcessor(
    InvoiceDbContext db, ErpClient erp, RetryPolicy policy, IOptions<OutboxOptions> options, TimeProvider time,
    ILogger<OutboxProcessor> logger)
{
    /// <summary>
    /// How long a taken entry belongs to the worker that took it (Outbox:LockSeconds). Longer than the longest attempt,
    /// so it never runs out during a send; if the service is killed mid-send, another worker takes the entry after this time.
    /// </summary>
    private TimeSpan LockDuration => TimeSpan.FromSeconds(options.Value.LockSeconds);

    /// <summary>
    /// Takes up to <paramref name="limit"/> pending entries whose time has come and that nobody holds. In one statement:
    /// FOR UPDATE SKIP LOCKED lets two instances run this at the same time without taking the same row (each skips the
    /// rows the other is taking), locked_until/locked_by mark the row as taken after the statement ends, and the attempt
    /// is counted before the send, so a send cut off by a crash is still counted. The count never goes past
    /// Outbox:MaxAttempts: an entry whose last attempt was cut off is taken again with the same number
    /// and only checked with the ERP (see <see cref="ClaimedEntry.AttemptsUsedUp"/>); the invoice's own count is not
    /// raised for it, since nothing is sent.
    /// </summary>
    public async Task<IReadOnlyList<ClaimedEntry>> ClaimAsync(int limit, string workerId, CancellationToken ct)
    {
        var now = time.GetUtcNow();
        var lockedUntil = now + LockDuration;

        return await db.Database.SqlQuery<ClaimedEntry>($"""
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
                SET attempt_count = LEAST(o.attempt_count + 1, {policy.MaxAttempts}),
                    locked_until = {lockedUntil},
                    locked_by = {workerId},
                    claim_token = gen_random_uuid()
                FROM due d
                WHERE o.id = d.id
                RETURNING o.id, o.invoice_number, o.attempt_count, d.attempt_count >= {policy.MaxAttempts} AS used_up, o.claim_token
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
    }

    /// <summary>
    /// Sends one taken entry and writes the outcome to erp_outbox and invoices in one transaction, following
    /// <see cref="RetryPolicy"/>: sent -> Gönderildi / Tamamlandı; retry -> both stay Bekliyor with next_attempt_at
    /// moved to now + wait; failed -> Başarısız on both.
    /// <para>
    /// Duplicate protection: the ERP can save an invoice and still not tell us (500 after saving, an answer later
    /// than our timeout, the service killed mid-send). So if the invoice was ever sent before, the ERP is asked first
    /// and the invoice is POSTed again only if the ERP clearly does not have it (404). If it has it, its reference is
    /// taken as the result. If it cannot be asked, nothing is sent: the attempt fails and is retried later.
    /// Limit: this relies on the ERP showing a request it has received by the time it is asked (at least ~2 s after
    /// our 10 s timeout). The simulator saves before it answers, so it always does; but if the ERP's own storage kept an
    /// earlier request waiting even longer, it would answer 404, the invoice would be posted again and both requests
    /// could end up saved. Only the ERP refusing a second record for the same invoice number would rule that out
    /// (the simulator does this when Simulator:IdempotentInvoices is on; it is off by default).
    /// </para>
    /// <para>
    /// Before giving up (all attempts used, or the last one cut off), the ERP is asked once more and nothing is sent:
    /// the last attempt may have been saved by the ERP without telling us (500 after saving, a late answer). If the ERP
    /// has the invoice it is Gönderildi with the ERP's reference; otherwise, or if the ERP cannot be asked, Başarısız.
    /// A later resend asks the ERP first as well, so an invoice the ERP already shows is not posted again.
    /// </para>
    /// </summary>
    public async Task SendAsync(ClaimedEntry entry, string workerId)
    {
        // CancellationToken.None: once the ERP is called, the outcome must be recorded even while the service stops.
        var invoice = await db.Invoices.AsNoTracking().SingleAsync(i => i.InvoiceNumber == entry.InvoiceNumber, CancellationToken.None);

        logger.LogInformation("ERP send start invoice={InvoiceNumber} attempt={Attempt}/{MaxAttempts} worker={Worker} claim={Claim}{OnlyCheck}",
            entry.InvoiceNumber, entry.Attempt, policy.MaxAttempts, workerId, entry.Claim,
            entry.AttemptsUsedUp ? " (last attempt was cut off: only asking the ERP)" : "");

        ErpSendResult result;
        string check;
        RetryDecision decision;
        if (entry.AttemptsUsedUp)
        {
            (result, check) = await ConfirmAsync(invoice, "Son deneme yarıda kaldı (servis durdu).");
            check = $"final:{check}";
            decision = FinalDecision(result, "last attempt was cut off; ERP asked, not sent again");
        }
        else
        {
            (result, check) = await SendOnceAsync(invoice, entry);
            if (check == NotHeld)
            {
                logger.LogWarning(
                    "ERP send invoice={InvoiceNumber} attempt={Attempt}/{MaxAttempts} worker={Worker} claim={Claim} check={Check} " +
                    "not sent: the entry is no longer held with this claim (its lock ran out and it was taken again)",
                    entry.InvoiceNumber, entry.Attempt, policy.MaxAttempts, workerId, entry.Claim, check);
                return;
            }
            decision = policy.Decide(result, entry.Attempt, time.GetUtcNow(), Random.Shared.NextDouble());
            if (decision.AttemptsUsedUp)
            {
                (result, var finalCheck) = await ConfirmAsync(invoice, result.Error);
                check = $"{check},final:{finalCheck}";
                decision = FinalDecision(result, $"all {policy.MaxAttempts} attempts used; ERP asked before giving up");
            }
        }

        var now = time.GetUtcNow();
        var (invoiceStatus, outboxStatus) = decision.Outcome switch
        {
            SendOutcome.Sent => (InvoiceStatus.Sent, OutboxStatus.Completed),
            SendOutcome.Failed => (InvoiceStatus.Failed, OutboxStatus.Failed),
            _ => (InvoiceStatus.Pending, OutboxStatus.Pending)
        };
        var done = decision.Outcome != SendOutcome.Retry;
        DateTimeOffset? processedAt = done ? now : null;
        var nextAttemptAt = done ? now : now + decision.Delay;

        await using var transaction = await db.Database.BeginTransactionAsync(CancellationToken.None);

        // Written only if the entry still carries this claim. If the lock ran out and the entry was taken again (by any
        // worker, with any attempt number), this older outcome is dropped instead of overwriting the newer one.
        var owned = await db.ErpOutbox
            .Where(o => o.Id == entry.Id && o.Status == OutboxStatus.Pending && o.ClaimToken == entry.ClaimToken)
            .ExecuteUpdateAsync(s => s
                .SetProperty(o => o.Status, outboxStatus)
                .SetProperty(o => o.LastError, result.Error)
                .SetProperty(o => o.NextAttemptAt, nextAttemptAt)
                .SetProperty(o => o.ProcessedAt, processedAt)
                .SetProperty(o => o.LockedUntil, (DateTimeOffset?)null)
                .SetProperty(o => o.LockedBy, (string?)null)
                .SetProperty(o => o.ClaimToken, (Guid?)null), CancellationToken.None);

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
            "ERP send invoice={InvoiceNumber} attempt={Attempt}/{MaxAttempts} worker={Worker} claim={Claim} check={Check} outcome={Outcome} http={HttpStatus} " +
            "retryAfter={RetryAfter} wait={WaitSeconds}s reason={Reason} erpReference={ErpReference} elapsed={ElapsedMs}ms error={Error}{NotWritten}",
            entry.InvoiceNumber, entry.Attempt, policy.MaxAttempts, workerId, entry.Claim, check, decision.Outcome, result.HttpStatus?.ToString() ?? "-",
            result.RetryAfter?.ToString() ?? "-", decision.Delay.TotalSeconds.ToString("0.000", CultureInfo.InvariantCulture),
            decision.Reason, result.ErpReference ?? "-", (long)result.Elapsed.TotalMilliseconds, result.Error ?? "-",
            owned == 1 ? "" : " (not written: the entry is no longer held by this worker)");
    }

    private static RetryDecision FinalDecision(ErpSendResult result, string reason) =>
        new(result.Accepted ? SendOutcome.Sent : SendOutcome.Failed, TimeSpan.Zero, reason);

    /// <summary>
    /// Asks the ERP whether it has the invoice, without sending it. Found -> accepted with the ERP's reference;
    /// not found -> failed with <paramref name="lastError"/>; ERP cannot be asked -> failed, the error says so.
    /// </summary>
    private async Task<(ErpSendResult Result, string Check)> ConfirmAsync(Invoice invoice, string? lastError)
    {
        var lookup = await erp.FindAsync(invoice.InvoiceNumber, CancellationToken.None);
        return lookup.Lookup switch
        {
            ErpLookup.Found => (new ErpSendResult(true, lookup.ErpReference, lookup.HttpStatus, null, lookup.Elapsed), "found"),
            ErpLookup.NotFound => (new ErpSendResult(false, null, lookup.HttpStatus, lastError, lookup.Elapsed), "notFound"),
            _ => (new ErpSendResult(false, null, null, $"{lastError} Son durum ERP'ye sorulamadı: {lookup.Error}", lookup.Elapsed), "unknown")
        };
    }

    /// <summary><c>Check</c> value when the entry was no longer held at the moment of sending: nothing sent, nothing written.</summary>
    private const string NotHeld = "notHeld";

    /// <summary>
    /// One attempt: POST directly the first time; otherwise ask the ERP first (see <see cref="SendAsync"/>).
    /// Right before a POST the entry must still be held with this claim and its lock must not have run out; otherwise
    /// nothing is sent (<see cref="NotHeld"/>): a worker that stalled past its lock must not send what another worker
    /// may be sending already.
    /// <c>Check</c> says which path was taken, for the log: first, found, notFound, unknown or notHeld.
    /// </summary>
    private async Task<(ErpSendResult Result, string Check)> SendOnceAsync(Invoice invoice, ClaimedEntry entry)
    {
        // send_attempt_count is counted per invoice for its whole life (a resend does not reset it) and already
        // includes this attempt, so 1 means nothing was ever sent before and the ERP cannot have the invoice.
        if (invoice.SendAttemptCount <= 1)
        {
            return await StillHeldAsync(entry)
                ? (await erp.SendAsync(invoice, CancellationToken.None), "first")
                : (new ErpSendResult(false, null, null, null, TimeSpan.Zero), NotHeld);
        }

        var lookup = await erp.FindAsync(invoice.InvoiceNumber, CancellationToken.None);
        if (lookup.Lookup == ErpLookup.NotFound && !await StillHeldAsync(entry))
            return (new ErpSendResult(false, null, null, null, lookup.Elapsed), NotHeld);

        return lookup.Lookup switch
        {
            ErpLookup.Found => (new ErpSendResult(true, lookup.ErpReference, lookup.HttpStatus, null, lookup.Elapsed), "found"),
            ErpLookup.NotFound => (await erp.SendAsync(invoice, CancellationToken.None), "notFound"),
            // No answer the ERP's state can be read from: treated like a timeout (backoff), never as "not there".
            _ => (new ErpSendResult(false, null, null, lookup.Error, lookup.Elapsed), "unknown")
        };
    }

    /// <summary>Whether the entry still carries this claim and its lock has not run out.</summary>
    private Task<bool> StillHeldAsync(ClaimedEntry entry)
    {
        var now = time.GetUtcNow();
        return db.ErpOutbox.AsNoTracking().AnyAsync(
            o => o.Id == entry.Id && o.ClaimToken == entry.ClaimToken && o.LockedUntil > now, CancellationToken.None);
    }
}
