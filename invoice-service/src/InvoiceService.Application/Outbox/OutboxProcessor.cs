using System.Diagnostics;
using System.Globalization;
using InvoiceService.Application.Abstractions;
using InvoiceService.Application.Metrics;
using InvoiceService.Application.Tracing;
using InvoiceService.Domain.Invoices;

namespace InvoiceService.Application.Outbox;

/// <summary>
/// Takes due outbox entries and sends them to the ERP. Runs the steps only: <see cref="ErpSendStrategy"/> sends,
/// <see cref="RetryPolicy"/> decides what the result means, <see cref="OutboxOutcomeWriter"/> writes it.
/// </summary>
public sealed class OutboxProcessor(
    IOutboxStore outbox, IInvoiceStore invoices, ErpSendStrategy strategy, OutboxOutcomeWriter outcomes,
    RetryPolicy policy, IOptions<OutboxOptions> options, TimeProvider time, InvoiceMetrics metrics, ILogger<OutboxProcessor> logger)
{
    /// <summary>How long a taken entry belongs to this worker; after that another worker may take it.</summary>
    private TimeSpan LockDuration => TimeSpan.FromSeconds(options.Value.LockSeconds);

    /// <summary>Takes up to <paramref name="limit"/> due entries that no other worker holds, counting the
    /// attempt.</summary>
    public Task<IReadOnlyList<ClaimedEntry>> ClaimAsync(int limit, string workerId, CancellationToken ct)
    {
        var now = time.GetUtcNow();
        return outbox.ClaimAsync(limit, workerId, now, now + LockDuration, policy.MaxAttempts, ct);
    }

    /// <summary>
    /// Makes one attempt and writes its outcome: Gönderildi, Bekliyor (retry later) or Başarısız. Before giving up, the
    /// ERP is asked once more, because the last attempt may have been saved without us being told.
    /// <paramref name="startedTrace"/>: the invoice's trace this attempt started (the entry's first time out of the
    /// queue). It is stored before the ERP is called, so the later attempts, the ERP's events and the steps taken on the
    /// invoice continue it.
    /// </summary>
    public async Task SendAsync(ClaimedEntry entry, string workerId, string? startedTrace = null)
    {
        // CancellationToken.None: once the ERP is called, the outcome must be recorded even while the service stops.
        // The worker's span for this attempt; the outcome is written on it as well as in the log.
        var span = Activity.Current;
        span?.SetTag(InvoiceTracing.InvoiceNumber, entry.InvoiceNumber);
        span?.SetTag("outbox.attempt", entry.Attempt);
        span?.SetTag("outbox.max_attempts", policy.MaxAttempts);

        var invoice = await invoices.GetAsync(entry.InvoiceNumber, CancellationToken.None);

        logger.LogInformation("ERP send start invoice={InvoiceNumber} attempt={Attempt}/{MaxAttempts} worker={Worker} claim={Claim}{OnlyCheck}",
            entry.InvoiceNumber, entry.Attempt, policy.MaxAttempts, workerId, entry.Claim,
            entry.AttemptsUsedUp ? " (last attempt was cut off: only asking the ERP)" : "");

        var held = startedTrace is null
            || await outbox.StartTraceAsync(entry.Id, entry.ClaimToken, startedTrace, CancellationToken.None);
        var outcome = !held ? null
            : entry.AttemptsUsedUp ? await ConfirmCutOffAttemptAsync(invoice)
            : await AttemptAsync(invoice, entry);

        if (outcome is null)
        {
            span?.SetTag("outbox.outcome", "NotHeld");
            logger.LogWarning(
                "ERP send invoice={InvoiceNumber} attempt={Attempt}/{MaxAttempts} worker={Worker} claim={Claim} check=notHeld " +
                "not sent: the entry is no longer held with this claim (its lock ran out and it was taken again)",
                entry.InvoiceNumber, entry.Attempt, policy.MaxAttempts, workerId, entry.Claim);
            return;
        }

        var (result, decision) = (outcome.Result, outcome.Decision);
        var owned = await outcomes.WriteAsync(entry, decision, result, time.GetUtcNow());
        TagOutcome(span, outcome);

        logger.LogInformation(
            "ERP send invoice={InvoiceNumber} attempt={Attempt}/{MaxAttempts} worker={Worker} claim={Claim} check={Check} outcome={Outcome} http={HttpStatus} " +
            "retryAfter={RetryAfter} wait={WaitSeconds}s reason={Reason} erpReference={ErpReference} elapsed={ElapsedMs}ms error={Error}{NotWritten}",
            entry.InvoiceNumber, entry.Attempt, policy.MaxAttempts, workerId, entry.Claim, outcome.Check, decision.Outcome,
            outcome.HttpStatus?.ToString() ?? "-",
            result.RetryAfter?.ToString() ?? "-", decision.Delay.TotalSeconds.ToString("0.000", CultureInfo.InvariantCulture),
            decision.Reason, result.ErpReference ?? "-", (long)result.Elapsed.TotalMilliseconds, result.Error ?? "-",
            owned ? "" : " (not written: the entry is no longer held by this worker)");
    }

    /// <summary>
    /// Sends once and decides what the result means. With no attempts left, the ERP is asked before giving up.
    /// Null when the entry is no longer held: nothing was sent.
    /// </summary>
    private async Task<AttemptOutcome?> AttemptAsync(Invoice invoice, ClaimedEntry entry)
    {
        var sent = await strategy.SendOnceAsync(invoice, entry);
        if (sent.Path == SendPath.NotHeld)
            return null;
        if (SendAttemptResult.Of(sent) is { } result)
            metrics.SendAttempt(result);

        var decision = policy.Decide(sent.Result, entry.Attempt, time.GetUtcNow(), Random.Shared.NextDouble());
        if (!decision.AttemptsUsedUp)
            return new AttemptOutcome(sent.Result, decision, sent.Check, sent.Result.HttpStatus);

        var final = await strategy.ConfirmAsync(invoice, sent.Result.Error);
        return new AttemptOutcome(
            final.Result, FinalDecision(final.Result, $"all {policy.MaxAttempts} attempts used; ERP asked before giving up"),
            $"{sent.Check},final:{final.Check}", sent.Result.HttpStatus);
    }

    /// <summary>
    /// The last attempt was cut off before its outcome was written: the ERP is only asked, not sent to again.
    /// </summary>
    private async Task<AttemptOutcome> ConfirmCutOffAttemptAsync(Invoice invoice)
    {
        var final = await strategy.ConfirmAsync(invoice, "Son deneme yarıda kaldı (servis durdu).");
        return new AttemptOutcome(
            final.Result, FinalDecision(final.Result, "last attempt was cut off; ERP asked, not sent again"),
            $"final:{final.Check}", final.Result.HttpStatus);
    }

    /// <summary>
    /// The attempt's number, result and wait on its span. A Bekliyor (retry) or Başarısız outcome is an error span, so
    /// failed attempts stand out in the trace.
    /// </summary>
    private static void TagOutcome(Activity? span, AttemptOutcome outcome)
    {
        if (span is null)
            return;
        var (result, decision) = (outcome.Result, outcome.Decision);
        span.SetTag("outbox.outcome", decision.Outcome.ToString());
        span.SetTag("outbox.check", outcome.Check);
        span.SetTag("outbox.reason", decision.Reason);
        // How long the entry waits before its next attempt (Retry-After or backoff); 0 when it is done.
        span.SetTag("outbox.wait_seconds", decision.Delay.TotalSeconds);
        span.SetTag("erp.http_status", outcome.HttpStatus);
        span.SetTag("erp.retry_after", result.RetryAfter?.ToString());
        span.SetTag("erp.reference", result.ErpReference);
        if (decision.Outcome != SendOutcome.Sent)
            span.SetStatus(ActivityStatusCode.Error, result.Error);
    }

    private static RetryDecision FinalDecision(ErpSendResult result, string reason) =>
        new(result.Accepted ? SendOutcome.Sent : SendOutcome.Failed, TimeSpan.Zero, reason);

    /// <param name="Result">What gets written: the attempt's result, or the final lookup's when the ERP was asked
    /// before giving up.</param>
    /// <param name="Check">The path for the log, e.g. "first", "found" or "notFound,final:found".</param>
    /// <param name="HttpStatus">The attempt's own HTTP status for the log, not the final lookup's.</param>
    private sealed record AttemptOutcome(ErpSendResult Result, RetryDecision Decision, string Check, int? HttpStatus);
}
