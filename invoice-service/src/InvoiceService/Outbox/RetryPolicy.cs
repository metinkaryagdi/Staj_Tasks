using System.Net.Http.Headers;
using InvoiceService.Erp;

namespace InvoiceService.Outbox;

public enum SendOutcome
{
    /// <summary>ERP accepted the invoice: Gönderildi / Tamamlandı.</summary>
    Sent,

    /// <summary>Try again after <see cref="RetryDecision.Delay"/>; the invoice stays Bekliyor.</summary>
    Retry,

    /// <summary>Permanent: Başarısız on both the invoice and the outbox entry.</summary>
    Failed
}

/// <param name="Reason">Why this delay, for the log (e.g. "Retry-After 17", "backoff 2^3=8s + jitter").</param>
/// <param name="AttemptsUsedUp">
/// Failed only because the last allowed attempt failed (not because the ERP rejected the invoice). The ERP may still have
/// saved the invoice on that attempt, so the caller asks it once more before giving up.
/// </param>
public sealed record RetryDecision(SendOutcome Outcome, TimeSpan Delay, string Reason, bool AttemptsUsedUp = false);

/// <summary>
/// What to do after one ERP attempt. Pure (time and randomness come in as arguments), so every rule is unit tested.
/// The limits come from the Outbox settings (<see cref="OutboxOptions"/>).
/// <list type="bullet">
/// <item>202 with a reference: sent.</item>
/// <item>429: wait as long as Retry-After says (seconds or HTTP date). No jitter: the ERP told us when.</item>
/// <item>Any other 4xx: the ERP rejected the invoice itself; trying again cannot help, so failed at once.</item>
/// <item>500, timeout, ERP unreachable (and anything else): exponential backoff 2, 4, 8 ... seconds, never more than
/// MaxBackoffSeconds, plus a random jitter.</item>
/// <item>The MaxAttempts-th attempt is the last: if it fails too, the invoice is failed.</item>
/// </list>
/// </summary>
public sealed class RetryPolicy(OutboxOptions options)
{
    public int MaxAttempts { get; } = options.MaxAttempts;

    /// <summary>No backoff wait is longer than this, jitter included.</summary>
    public TimeSpan MaxBackoff { get; } = TimeSpan.FromSeconds(options.MaxBackoffSeconds);

    /// <summary>The jitter is a random value in [0, this).</summary>
    public TimeSpan MaxJitter { get; } = TimeSpan.FromMilliseconds(options.MaxJitterMilliseconds);

    /// <param name="attempt">Number of the attempt that just finished (1 = first).</param>
    /// <param name="random">A random number in [0, 1) for the jitter.</param>
    public RetryDecision Decide(ErpSendResult result, int attempt, DateTimeOffset now, double random)
    {
        if (result.Accepted)
            return new RetryDecision(SendOutcome.Sent, TimeSpan.Zero, "accepted");

        if (result.HttpStatus is >= 400 and < 500 and not 429)
            return new RetryDecision(SendOutcome.Failed, TimeSpan.Zero, $"ERP rejected the invoice with {result.HttpStatus}, not retried");

        if (attempt >= MaxAttempts)
            return new RetryDecision(SendOutcome.Failed, TimeSpan.Zero, $"all {MaxAttempts} attempts used", AttemptsUsedUp: true);

        if (result.HttpStatus == 429 && RetryAfterDelay(result.RetryAfter, now) is { } wait)
            return new RetryDecision(SendOutcome.Retry, wait, $"Retry-After {result.RetryAfter}");

        // 429 without a usable Retry-After falls through to the backoff.
        var (delay, reason) = Backoff(attempt, random);
        return new RetryDecision(SendOutcome.Retry, delay, reason);
    }

    /// <summary>
    /// Retry-After as a wait: "17" -> 17 s; an HTTP date -> the time left until then (0 if it is already past).
    /// Null if there is no header.
    /// </summary>
    public static TimeSpan? RetryAfterDelay(RetryConditionHeaderValue? retryAfter, DateTimeOffset now)
    {
        if (retryAfter?.Delta is { } delta)
            return delta;
        if (retryAfter?.Date is { } date)
            return date > now ? date - now : TimeSpan.Zero;
        return null;
    }

    /// <summary>
    /// 2^attempt seconds (2, 4, 8, 16, 32, ...) plus jitter in [0, MaxJitter). The base is capped at
    /// MaxBackoff - MaxJitter (59 s with the shipped settings), so with the jitter the wait is never more than MaxBackoff
    /// and the capped waits are still spread out.
    /// Why jitter: invoices that failed together (e.g. while the ERP was down) would otherwise all retry at exactly
    /// the same moment, again and again, and hit the recovering ERP as one burst.
    /// </summary>
    public (TimeSpan Delay, string Reason) Backoff(int attempt, double random)
    {
        var exponential = TimeSpan.FromSeconds(Math.Pow(2, Math.Min(attempt, 30)));
        var cap = MaxBackoff - MaxJitter;
        var baseDelay = exponential < cap ? exponential : cap;
        var jitter = MaxJitter * Math.Clamp(random, 0, 0.999);
        return (baseDelay + jitter, $"backoff {baseDelay.TotalSeconds:0}s + jitter {jitter.TotalMilliseconds:0}ms");
    }
}
