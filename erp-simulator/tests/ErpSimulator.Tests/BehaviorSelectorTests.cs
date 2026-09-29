using ErpSimulator.Simulation;
using Microsoft.Extensions.Options;

namespace ErpSimulator.Tests;

public class BehaviorSelectorTests
{
    private static BehaviorSelector Create(int seed = 42, BehaviorRates? rates = null) =>
        new(Options.Create(new SimulatorOptions { Seed = seed, Rates = rates ?? new BehaviorRates() }));

    private static List<Behavior> Draw(BehaviorSelector selector, int count) =>
        Enumerable.Range(0, count).Select(_ => selector.Next().Behavior).ToList();

    [Fact]
    public void Same_seed_produces_same_sequence()
    {
        Assert.Equal(Draw(Create(seed: 7), 500), Draw(Create(seed: 7), 500));
    }

    [Fact]
    public void Different_seed_produces_different_sequence()
    {
        Assert.NotEqual(Draw(Create(seed: 1), 100), Draw(Create(seed: 2), 100));
    }

    [Fact]
    public void All_failure_rates_zero_means_always_success()
    {
        var selector = Create(rates: new BehaviorRates { Busy = 0, ServerError = 0, SaveThenError = 0, LateResponse = 0 });
        Assert.All(Draw(selector, 1000), b => Assert.Equal(Behavior.Success, b));
    }

    [Theory]
    [InlineData(Behavior.Busy)]
    [InlineData(Behavior.ServerError)]
    [InlineData(Behavior.SaveThenError)]
    [InlineData(Behavior.LateResponse)]
    public void Rate_of_100_always_picks_that_behavior(Behavior expected)
    {
        var rates = new BehaviorRates
        {
            Busy = expected == Behavior.Busy ? 100 : 0,
            ServerError = expected == Behavior.ServerError ? 100 : 0,
            SaveThenError = expected == Behavior.SaveThenError ? 100 : 0,
            LateResponse = expected == Behavior.LateResponse ? 100 : 0
        };
        Assert.All(Draw(Create(rates: rates), 1000), b => Assert.Equal(expected, b));
    }

    [Fact]
    public void Default_rates_roughly_match_configured_distribution()
    {
        const int n = 100_000;
        var counts = Draw(Create(), n).GroupBy(b => b).ToDictionary(g => g.Key, g => g.Count() * 100.0 / n);

        Assert.InRange(counts[Behavior.Success], 59, 61);
        Assert.InRange(counts[Behavior.Busy], 14, 16);
        Assert.InRange(counts[Behavior.ServerError], 9, 11);
        Assert.InRange(counts[Behavior.SaveThenError], 4, 6);
        Assert.InRange(counts[Behavior.LateResponse], 9, 11);
    }

    [Fact]
    public void Retry_after_is_within_configured_range()
    {
        var selector = Create();
        var values = Enumerable.Range(0, 10_000).Select(_ => selector.Next().RetryAfterSeconds).ToList();

        Assert.Equal(5, values.Min());
        Assert.Equal(30, values.Max());
    }

    [Fact]
    public void Validator_rejects_rates_that_exceed_100()
    {
        var options = new SimulatorOptions { Rates = new BehaviorRates { Busy = 60, ServerError = 50 } };
        Assert.True(new SimulatorOptionsValidator().Validate(null, options).Failed);
    }
}
