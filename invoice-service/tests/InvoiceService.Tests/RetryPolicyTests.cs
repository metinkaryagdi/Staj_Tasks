using System.Net.Http.Headers;
using InvoiceService.Erp;
using InvoiceService.Outbox;

namespace InvoiceService.Tests;

public class RetryPolicyTests
{
    private static readonly DateTimeOffset Now = new(2026, 10, 1, 7, 0, 0, TimeSpan.Zero);

    private static ErpSendResult Result(int? status, RetryConditionHeaderValue? retryAfter = null, bool accepted = false) =>
        new(accepted, accepted ? "ERP-00000001" : null, status, accepted ? null : "error", TimeSpan.Zero, retryAfter);

    [Fact]
    public void Accepted_is_sent()
    {
        var decision = RetryPolicy.Decide(Result(202, accepted: true), attempt: 1, Now, random: 0.5);
        Assert.Equal(SendOutcome.Sent, decision.Outcome);
    }

    [Fact]
    public void Busy_waits_exactly_the_retry_after_seconds()
    {
        var decision = RetryPolicy.Decide(Result(429, new RetryConditionHeaderValue(TimeSpan.FromSeconds(17))), 1, Now, 0.9);

        Assert.Equal(SendOutcome.Retry, decision.Outcome);
        Assert.Equal(TimeSpan.FromSeconds(17), decision.Delay);
    }

    [Fact]
    public void Busy_waits_until_the_retry_after_date()
    {
        var decision = RetryPolicy.Decide(Result(429, new RetryConditionHeaderValue(Now.AddSeconds(23))), 1, Now, 0.9);

        Assert.Equal(SendOutcome.Retry, decision.Outcome);
        Assert.Equal(TimeSpan.FromSeconds(23), decision.Delay);
    }

    [Fact]
    public void Retry_after_date_in_the_past_means_no_wait()
    {
        var decision = RetryPolicy.Decide(Result(429, new RetryConditionHeaderValue(Now.AddSeconds(-5))), 1, Now, 0.9);
        Assert.Equal(TimeSpan.Zero, decision.Delay);
    }

    [Fact]
    public void Busy_without_retry_after_falls_back_to_backoff()
    {
        var decision = RetryPolicy.Decide(Result(429), 3, Now, 0);
        Assert.Equal(TimeSpan.FromSeconds(8), decision.Delay);
    }

    [Theory]
    [InlineData(400)]
    [InlineData(404)]
    [InlineData(409)]
    [InlineData(422)]
    public void Other_4xx_fails_at_once(int status)
    {
        var decision = RetryPolicy.Decide(Result(status), attempt: 1, Now, 0.5);
        Assert.Equal(SendOutcome.Failed, decision.Outcome);
    }

    [Theory]
    [InlineData(500)]
    [InlineData(503)]
    [InlineData(null)] // timeout or ERP unreachable: no answer at all
    public void Server_error_timeout_and_unreachable_are_retried_with_backoff(int? status)
    {
        var decision = RetryPolicy.Decide(Result(status), attempt: 1, Now, 0);

        Assert.Equal(SendOutcome.Retry, decision.Outcome);
        Assert.Equal(TimeSpan.FromSeconds(2), decision.Delay);
    }

    [Theory]
    [InlineData(1, 2)]
    [InlineData(2, 4)]
    [InlineData(3, 8)]
    [InlineData(4, 16)]
    [InlineData(5, 32)]
    [InlineData(6, 59)]
    [InlineData(9, 59)]
    public void Backoff_doubles_and_is_capped(int attempt, int expectedBaseSeconds)
    {
        var (delay, _) = RetryPolicy.Backoff(attempt, random: 0);
        Assert.Equal(TimeSpan.FromSeconds(expectedBaseSeconds), delay);
    }

    [Theory]
    [InlineData(1)]
    [InlineData(5)]
    [InlineData(6)]
    [InlineData(9)]
    public void Jitter_adds_less_than_a_second_and_never_goes_past_60_seconds(int attempt)
    {
        var (lowest, _) = RetryPolicy.Backoff(attempt, random: 0);
        var (highest, _) = RetryPolicy.Backoff(attempt, random: 1);

        Assert.True(highest > lowest);
        Assert.True(highest - lowest < TimeSpan.FromSeconds(1));
        Assert.True(highest <= TimeSpan.FromSeconds(60));
    }

    [Fact]
    public void The_10th_failed_attempt_is_final()
    {
        Assert.Equal(SendOutcome.Retry, RetryPolicy.Decide(Result(500), attempt: 9, Now, 0.5).Outcome);
        Assert.Equal(SendOutcome.Failed, RetryPolicy.Decide(Result(500), attempt: 10, Now, 0.5).Outcome);
        Assert.Equal(SendOutcome.Failed,
            RetryPolicy.Decide(Result(429, new RetryConditionHeaderValue(TimeSpan.FromSeconds(5))), attempt: 10, Now, 0.5).Outcome);
    }

    [Fact]
    public void Only_used_up_attempts_ask_the_erp_before_giving_up()
    {
        // The ERP may have saved the invoice on the last attempt (500 after saving, late answer): ask before failing.
        Assert.True(RetryPolicy.Decide(Result(500), attempt: 10, Now, 0.5).AttemptsUsedUp);
        Assert.True(RetryPolicy.Decide(Result(null), attempt: 10, Now, 0.5).AttemptsUsedUp);
        // The ERP rejected the invoice itself: nothing was saved, nothing to ask.
        Assert.False(RetryPolicy.Decide(Result(422), attempt: 10, Now, 0.5).AttemptsUsedUp);
        Assert.False(RetryPolicy.Decide(Result(422), attempt: 1, Now, 0.5).AttemptsUsedUp);
        // Still attempts left.
        Assert.False(RetryPolicy.Decide(Result(500), attempt: 9, Now, 0.5).AttemptsUsedUp);
    }

    [Fact]
    public void The_10th_attempt_can_still_succeed()
    {
        Assert.Equal(SendOutcome.Sent, RetryPolicy.Decide(Result(202, accepted: true), attempt: 10, Now, 0.5).Outcome);
    }
}
