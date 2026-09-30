using Microsoft.Extensions.Options;

namespace ErpSimulator.Simulation;

public enum Behavior
{
    Success,
    Busy,
    ServerError,
    SaveThenError,
    LateResponse
}

public sealed record BehaviorDecision(long Sequence, Behavior Behavior, int RetryAfterSeconds);

/// <summary>
/// Picks a behavior for every incoming POST from a single seeded RNG.
/// Each decision always consumes exactly two draws (behavior roll + Retry-After value),
/// so the sequence depends only on the seed and the order of requests, never on which
/// behavior happened to be chosen before.
/// </summary>
public sealed class BehaviorSelector
{
    private readonly Lock _lock = new();
    private readonly Random _random;
    private readonly SimulatorOptions _options;
    private readonly (Behavior Behavior, double Rate)[] _table;
    private long _sequence;

    public BehaviorSelector(IOptions<SimulatorOptions> options)
    {
        _options = options.Value;
        _random = new Random(_options.Seed);

        var rates = _options.Rates;
        _table =
        [
            (Behavior.Success, rates.Success),
            (Behavior.Busy, rates.Busy),
            (Behavior.ServerError, rates.ServerError),
            (Behavior.SaveThenError, rates.SaveThenError),
            (Behavior.LateResponse, rates.LateResponse)
        ];
    }

    public BehaviorDecision Next()
    {
        lock (_lock)
        {
            // Rates are validated to add up to 100, so each one is a plain percentage.
            var roll = _random.NextDouble() * BehaviorRates.RequiredTotal;
            var retryAfter = _random.Next(_options.RetryAfterMinSeconds, _options.RetryAfterMaxSeconds + 1);
            _sequence++;
            return new BehaviorDecision(_sequence, Pick(roll), retryAfter);
        }
    }

    private Behavior Pick(double roll)
    {
        double cumulative = 0;
        foreach (var (behavior, rate) in _table)
        {
            cumulative += rate;
            if (roll < cumulative)
                return behavior;
        }

        // Floating point leftovers: fall back to the last behavior that has a non-zero rate.
        return _table.Last(entry => entry.Rate > 0).Behavior;
    }
}
