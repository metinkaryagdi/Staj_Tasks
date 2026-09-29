using Microsoft.Extensions.Options;

namespace ErpSimulator.Simulation;

public sealed class SimulatorOptions
{
    public const string SectionName = "Simulator";

    /// <summary>Seed for the behavior RNG. Same seed + same request order = same behavior sequence.</summary>
    public int Seed { get; set; } = 42;

    /// <summary>Failure rates in percent. Success gets whatever is left up to 100.</summary>
    public BehaviorRates Rates { get; set; } = new();

    public int LateResponseDelaySeconds { get; set; } = 30;

    public int RetryAfterMinSeconds { get; set; } = 5;

    public int RetryAfterMaxSeconds { get; set; } = 30;

    /// <summary>RFC 9110 allows Retry-After as delay-seconds ("17") or as an HTTP-date.</summary>
    public RetryAfterFormat RetryAfterFormat { get; set; } = RetryAfterFormat.Seconds;
}

public sealed class BehaviorRates
{
    public double Busy { get; set; } = 15;
    public double ServerError { get; set; } = 10;
    public double SaveThenError { get; set; } = 5;
    public double LateResponse { get; set; } = 10;

    public double FailureTotal => Busy + ServerError + SaveThenError + LateResponse;

    public double Success => Math.Max(0, 100 - FailureTotal);
}

public enum RetryAfterFormat
{
    Seconds,
    HttpDate
}

public sealed class SimulatorOptionsValidator : IValidateOptions<SimulatorOptions>
{
    public ValidateOptionsResult Validate(string? name, SimulatorOptions options)
    {
        var errors = new List<string>();
        var rates = options.Rates;

        foreach (var (rateName, value) in new[]
                 {
                     (nameof(rates.Busy), rates.Busy),
                     (nameof(rates.ServerError), rates.ServerError),
                     (nameof(rates.SaveThenError), rates.SaveThenError),
                     (nameof(rates.LateResponse), rates.LateResponse)
                 })
        {
            if (value is < 0 or > 100)
                errors.Add($"Simulator:Rates:{rateName} must be between 0 and 100 (was {value}).");
        }

        if (rates.FailureTotal > 100)
            errors.Add($"Sum of failure rates must not exceed 100 (was {rates.FailureTotal}).");

        if (options.LateResponseDelaySeconds < 0)
            errors.Add("Simulator:LateResponseDelaySeconds must not be negative.");

        if (options.RetryAfterMinSeconds < 0 || options.RetryAfterMaxSeconds < options.RetryAfterMinSeconds)
            errors.Add("Simulator:RetryAfterMinSeconds/RetryAfterMaxSeconds must satisfy 0 <= min <= max.");

        return errors.Count == 0 ? ValidateOptionsResult.Success : ValidateOptionsResult.Fail(errors);
    }
}
