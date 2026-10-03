using System.Globalization;
using InvoiceService.Application.Abstractions;
using InvoiceService.Domain.Invoices;

namespace InvoiceService.Application.Outbox;

/// <summary>
/// A queued send the worker has taken: <see cref="Attempt"/> is this attempt's number (already counted).
/// <see cref="AttemptsUsedUp"/>: the entry had already used all its attempts when it was taken, i.e. the last attempt was
/// cut off (the service stopped before writing its outcome). Such an entry is not sent again; the ERP is only asked.
/// <see cref="ClaimToken"/>: the id of this taking (erp_outbox.claim_token); see <see cref="Domain.Outbox.ErpOutboxEntry.ClaimToken"/>.
/// </summary>
public sealed record ClaimedEntry(long Id, string InvoiceNumber, int Attempt, bool AttemptsUsedUp, Guid ClaimToken)
{
    /// <summary>Short form of the claim token for the log.</summary>
    public string Claim => ClaimToken.ToString("N")[..8];
}

/// <summary>
/// Takes due entries from erp_outbox and sends them. Scoped: one instance (and one unit of work) per claim or per send.
/// It only conducts the steps: taking is <see cref="IOutboxStore"/>, the "ask first, then POST" decision is
/// <see cref="ErpSendStrategy"/>, what to do after an attempt is <see cref="RetryPolicy"/>, and writing the outcome is
/// <see cref="OutboxOutcomeWriter"/>.
/// </summary>
public sealed class OutboxProcessor(
    IOutboxStore outbox, IInvoiceStore invoices, ErpSendStrategy strategy, OutboxOutcomeWriter outcomes,
    RetryPolicy policy, IOptions<OutboxOptions> options, TimeProvider time, ILogger<OutboxProcessor> logger)
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
    public Task<IReadOnlyList<ClaimedEntry>> ClaimAsync(int limit, string workerId, CancellationToken ct)
    {
        var now = time.GetUtcNow();
        return outbox.ClaimAsync(limit, workerId, now, now + LockDuration, policy.MaxAttempts, ct);
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
        var invoice = await invoices.GetAsync(entry.InvoiceNumber, CancellationToken.None);

        logger.LogInformation("ERP send start invoice={InvoiceNumber} attempt={Attempt}/{MaxAttempts} worker={Worker} claim={Claim}{OnlyCheck}",
            entry.InvoiceNumber, entry.Attempt, policy.MaxAttempts, workerId, entry.Claim,
            entry.AttemptsUsedUp ? " (last attempt was cut off: only asking the ERP)" : "");

        ErpSendResult result;
        string check;
        RetryDecision decision;
        // HTTP status shown in the log: the attempt's own request, not the final "ask before giving up" lookup
        // (its outcome is already in check=final:...).
        int? httpStatus;
        if (entry.AttemptsUsedUp)
        {
            (result, check) = await strategy.ConfirmAsync(invoice, "Son deneme yarıda kaldı (servis durdu).");
            check = $"final:{check}";
            decision = FinalDecision(result, "last attempt was cut off; ERP asked, not sent again");
            httpStatus = result.HttpStatus;
        }
        else
        {
            (result, check) = await strategy.SendOnceAsync(invoice, entry);
            if (check == ErpSendStrategy.NotHeld)
            {
                logger.LogWarning(
                    "ERP send invoice={InvoiceNumber} attempt={Attempt}/{MaxAttempts} worker={Worker} claim={Claim} check={Check} " +
                    "not sent: the entry is no longer held with this claim (its lock ran out and it was taken again)",
                    entry.InvoiceNumber, entry.Attempt, policy.MaxAttempts, workerId, entry.Claim, check);
                return;
            }
            decision = policy.Decide(result, entry.Attempt, time.GetUtcNow(), Random.Shared.NextDouble());
            httpStatus = result.HttpStatus;
            if (decision.AttemptsUsedUp)
            {
                (result, var finalCheck) = await strategy.ConfirmAsync(invoice, result.Error);
                check = $"{check},final:{finalCheck}";
                decision = FinalDecision(result, $"all {policy.MaxAttempts} attempts used; ERP asked before giving up");
            }
        }

        var now = time.GetUtcNow();
        var owned = await outcomes.WriteAsync(entry, decision, result, now);

        logger.LogInformation(
            "ERP send invoice={InvoiceNumber} attempt={Attempt}/{MaxAttempts} worker={Worker} claim={Claim} check={Check} outcome={Outcome} http={HttpStatus} " +
            "retryAfter={RetryAfter} wait={WaitSeconds}s reason={Reason} erpReference={ErpReference} elapsed={ElapsedMs}ms error={Error}{NotWritten}",
            entry.InvoiceNumber, entry.Attempt, policy.MaxAttempts, workerId, entry.Claim, check, decision.Outcome, httpStatus?.ToString() ?? "-",
            result.RetryAfter?.ToString() ?? "-", decision.Delay.TotalSeconds.ToString("0.000", CultureInfo.InvariantCulture),
            decision.Reason, result.ErpReference ?? "-", (long)result.Elapsed.TotalMilliseconds, result.Error ?? "-",
            owned ? "" : " (not written: the entry is no longer held by this worker)");
    }

    private static RetryDecision FinalDecision(ErpSendResult result, string reason) =>
        new(result.Accepted ? SendOutcome.Sent : SendOutcome.Failed, TimeSpan.Zero, reason);
}
