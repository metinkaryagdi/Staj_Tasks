using Microsoft.Extensions.Options;

namespace ErpSimulator.Simulation;

/// <summary>
/// Bound from the "Simulator" section of appsettings.json. There are no defaults in code:
/// every value must be present in the settings file, otherwise the app refuses to start.
/// </summary>
public sealed class SimulatorOptions
{
    public const string SectionName = "Simulator";

    /// <summary>Seed for the behavior RNG. Same seed + same request order = same behavior sequence.</summary>
    public int Seed { get; set; }

    /// <summary>
    /// Behavior rates in percent. Each behavior's chance is its rate divided by <see cref="BehaviorRates.Total"/>,
    /// so with every failure rate at 0 the simulator always succeeds regardless of the Success value.
    /// </summary>
    public BehaviorRates Rates { get; set; } = new();

    public int LateResponseDelaySeconds { get; set; }

    public int RetryAfterMinSeconds { get; set; }

    public int RetryAfterMaxSeconds { get; set; }

    /// <summary>RFC 9110 allows Retry-After as delay-seconds ("17") or as an HTTP-date.</summary>
    public RetryAfterFormat RetryAfterFormat { get; set; }
}

public sealed class BehaviorRates
{
    public double Success { get; set; }
    public double Busy { get; set; }
    public double ServerError { get; set; }
    public double SaveThenError { get; set; }
    public double LateResponse { get; set; }

    public double Total => Success + Busy + ServerError + SaveThenError + LateResponse;

    /// <summary>Actual chance of <paramref name="rate"/> in percent after normalizing by <see cref="Total"/>.</summary>
    public double Effective(double rate) => Total > 0 ? rate * 100 / Total : 0;
}

public enum RetryAfterFormat
{
    Seconds,
    HttpDate
}

public sealed class SimulatorOptionsValidator(IConfiguration configuration) : IValidateOptions<SimulatorOptions>
{
    /// <summary>Keys that must exist under the "Simulator" section of the settings file.</summary>
    public static readonly string[] RequiredKeys =
    [
        "Seed",
        "Rates:Success",
        "Rates:Busy",
        "Rates:ServerError",
        "Rates:SaveThenError",
        "Rates:LateResponse",
        "LateResponseDelaySeconds",
        "RetryAfterMinSeconds",
        "RetryAfterMaxSeconds",
        "RetryAfterFormat"
    ];

    public ValidateOptionsResult Validate(string? name, SimulatorOptions options)
    {
        var errors = new List<string>();
        var rates = options.Rates;

        var section = configuration.GetSection(SimulatorOptions.SectionName);
        foreach (var key in RequiredKeys)
        {
            if (string.IsNullOrWhiteSpace(section[key]))
                errors.Add($"{SimulatorOptions.SectionName}:{key} is missing from the settings file.");
        }

        foreach (var (rateName, value) in new[]
                 {
                     (nameof(rates.Success), rates.Success),
                     (nameof(rates.Busy), rates.Busy),
                     (nameof(rates.ServerError), rates.ServerError),
                     (nameof(rates.SaveThenError), rates.SaveThenError),
                     (nameof(rates.LateResponse), rates.LateResponse)
                 })
        {
            if (value is < 0 or > 100)
                errors.Add($"Simulator:Rates:{rateName} must be between 0 and 100 (was {value}).");
        }

        if (rates.Total <= 0)
            errors.Add("At least one Simulator:Rates value must be greater than 0.");

        if (options.LateResponseDelaySeconds < 0)
            errors.Add("Simulator:LateResponseDelaySeconds must not be negative.");

        if (options.RetryAfterMinSeconds < 0 || options.RetryAfterMaxSeconds < options.RetryAfterMinSeconds)
            errors.Add("Simulator:RetryAfterMinSeconds/RetryAfterMaxSeconds must satisfy 0 <= min <= max.");

        return errors.Count == 0 ? ValidateOptionsResult.Success : ValidateOptionsResult.Fail(errors);
    }
}
