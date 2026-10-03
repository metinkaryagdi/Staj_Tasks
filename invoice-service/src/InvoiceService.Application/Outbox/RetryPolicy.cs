using System.Net.Http.Headers;
using InvoiceService.Application.Abstractions;

namespace InvoiceService.Application.Outbox;

public enum SendOutcome
{
    /// <summary>ERP accepted the invoice: Gönderildi / Tamamlandı.</summary>
    Sent,

    /// <summary>Try again after <see cref="RetryDecision.Delay"/>; the invoice stays Bekliyor.</summary>
    Retry,

    /// <summary>Permanent: Başarısız on both the invoice and the outbox entry.</summary>
    Failed
}

/// <param name="Reason">Why this decision, for the log.</param>
/// <param name="AttemptsUsedUp">Failed because no attempts are left (not because the ERP refused the invoice).</param>
public sealed record RetryDecision(SendOutcome Outcome, TimeSpan Delay, string Reason, bool AttemptsUsedUp = false);

/// <summary>
/// What to do after one ERP attempt: 202 -> sent; 429 -> wait for Retry-After; other 4xx -> failed at once;
/// anything else -> exponential backoff with jitter. After the last attempt -> failed.
/// </summary>
public sealed class RetryPolicy(OutboxOptions options)
{
    public int MaxAttempts { get; } = options.MaxAttempts;

    /// <summary>No backoff wait is longer than this, jitter included.</summary>
    public TimeSpan MaxBackoff { get; } = TimeSpan.FromSeconds(options.MaxBackoffSeconds);

    /// <summary>The jitter is a random value in [0, this).</summary>
    public TimeSpan MaxJitter { get; } = TimeSpan.FromMilliseconds(options.MaxJitterMilliseconds);

    /// <summary>Room left below <see cref="MaxBackoff"/>.</summary>
    public TimeSpan BackoffMargin { get; } = TimeSpan.FromMilliseconds(options.BackoffMarginMilliseconds);

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

    /// <summary>Retry-After as a wait: "17" -> 17 s; an HTTP date -> the time left until then. Null without the header.</summary>
    public static TimeSpan? RetryAfterDelay(RetryConditionHeaderValue? retryAfter, DateTimeOffset now)
    {
        if (retryAfter?.Delta is { } delta)
            return delta;
        if (retryAfter?.Date is { } date)
            return date > now ? date - now : TimeSpan.Zero;
        return null;
    }

    /// <summary>
    /// 2, 4, 8 ... seconds plus a random jitter, capped so that the total never passes MaxBackoff. The jitter spreads out
    /// invoices that failed together, so they do not all hit the recovering ERP at the same moment.
    /// </summary>
    public (TimeSpan Delay, string Reason) Backoff(int attempt, double random)
    {
        var exponential = TimeSpan.FromSeconds(Math.Pow(2, Math.Min(attempt, 30)));
        var cap = MaxBackoff - MaxJitter - BackoffMargin;
        var baseDelay = exponential < cap ? exponential : cap;
        var jitter = MaxJitter * Math.Clamp(random, 0, 0.999);
        return (baseDelay + jitter, $"backoff {baseDelay.TotalSeconds:0}s + jitter {jitter.TotalMilliseconds:0}ms");
    }
}
