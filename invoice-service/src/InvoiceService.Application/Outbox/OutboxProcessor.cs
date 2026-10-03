using System.Globalization;
using InvoiceService.Application.Abstractions;
using InvoiceService.Domain.Invoices;

namespace InvoiceService.Application.Outbox;

/// <summary>
/// An outbox entry the worker has taken. <see cref="Attempt"/> is already counted. <see cref="AttemptsUsedUp"/>: the last
/// attempt was cut off before its outcome was written, so the ERP is only asked, not sent to again.
/// </summary>
public sealed record ClaimedEntry(long Id, string InvoiceNumber, int Attempt, bool AttemptsUsedUp, Guid ClaimToken)
{
    /// <summary>Short form of the claim token for the log.</summary>
    public string Claim => ClaimToken.ToString("N")[..8];
}

/// <summary>
/// Takes due outbox entries and sends them to the ERP. Runs the steps only: <see cref="ErpSendStrategy"/> sends,
/// <see cref="RetryPolicy"/> decides what the result means, <see cref="OutboxOutcomeWriter"/> writes it.
/// </summary>
public sealed class OutboxProcessor(
    IOutboxStore outbox, IInvoiceStore invoices, ErpSendStrategy strategy, OutboxOutcomeWriter outcomes,
    RetryPolicy policy, IOptions<OutboxOptions> options, TimeProvider time, ILogger<OutboxProcessor> logger)
{
    /// <summary>How long a taken entry belongs to this worker; after that another worker may take it.</summary>
    private TimeSpan LockDuration => TimeSpan.FromSeconds(options.Value.LockSeconds);

    /// <summary>Takes up to <paramref name="limit"/> due entries that no other worker holds, counting the attempt.</summary>
    public Task<IReadOnlyList<ClaimedEntry>> ClaimAsync(int limit, string workerId, CancellationToken ct)
    {
        var now = time.GetUtcNow();
        return outbox.ClaimAsync(limit, workerId, now, now + LockDuration, policy.MaxAttempts, ct);
    }

    /// <summary>
    /// Makes one attempt and writes its outcome: Gönderildi, Bekliyor (retry later) or Başarısız. Before giving up, the
    /// ERP is asked once more, because the last attempt may have been saved without us being told.
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
        // The log shows the attempt's own HTTP status, not the final lookup's.
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
