using ErpSimulator.Application.Simulation;
using Microsoft.Extensions.Options;

namespace ErpSimulator.Application.Tests;

public class InvoiceRateLimiterTests
{
    private static InvoiceRateLimiter Create(int perSecond) =>
        new(Options.Create(new RateLimitOptions { PermitsPerSecond = perSecond }));

    private static int AcquireAll(InvoiceRateLimiter limiter, int tries) =>
        Enumerable.Range(0, tries).Count(_ => limiter.TryAcquire());

    [Fact]
    public void Accepts_the_limit_then_rejects_until_refilled()
    {
        var limiter = Create(20);

        Assert.Equal(20, AcquireAll(limiter, 50));
        Assert.False(limiter.TryAcquire());

        limiter.Refill();
        Assert.Equal(20, AcquireAll(limiter, 50));
    }

    [Fact]
    public void Refill_never_holds_more_than_the_limit()
    {
        var limiter = Create(20);

        // Unused tokens are not carried over: two refills of a full bucket still give one second's worth.
        limiter.Refill();
        limiter.Refill();

        Assert.Equal(20, AcquireAll(limiter, 50));
    }

    [Fact]
    public void Refill_tops_up_a_partly_used_bucket_to_the_limit()
    {
        var limiter = Create(20);
        Assert.Equal(5, AcquireAll(limiter, 5));

        limiter.Refill();

        Assert.Equal(20, AcquireAll(limiter, 50));
    }

    [Theory]
    [InlineData("2026-10-08T06:36:00.000Z", "2026-10-08T06:36:01.000Z")]
    [InlineData("2026-10-08T06:36:00.001Z", "2026-10-08T06:36:01.000Z")]
    [InlineData("2026-10-08T06:36:00.999Z", "2026-10-08T06:36:01.000Z")]
    [InlineData("2026-10-08T09:36:59.500+03:00", "2026-10-08T06:37:00.000Z")]
    public void Next_second_is_the_start_of_the_following_clock_second(string now, string expected)
    {
        Assert.Equal(DateTimeOffset.Parse(expected), InvoiceRateLimiter.NextSecond(DateTimeOffset.Parse(now)));
    }
}
