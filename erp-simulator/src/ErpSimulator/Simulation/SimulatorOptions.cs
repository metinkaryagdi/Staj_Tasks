using System.Globalization;
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
    /// Behavior rates in percent. They must add up to exactly 100, so each value is the behavior's real chance;
    /// a perfect ERP is Success = 100 with every failure rate at 0.
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

    public const double RequiredTotal = 100;

    public double Total => Success + Busy + ServerError + SaveThenError + LateResponse;
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

        // Small tolerance only for floating point sums such as 33.3 + 33.3 + 33.4.
        if (Math.Abs(rates.Total - BehaviorRates.RequiredTotal) > 1e-9)
            errors.Add(
                $"Simulator:Rates must add up to exactly {BehaviorRates.RequiredTotal} (was {Format(rates.Total)}: " +
                $"Success={Format(rates.Success)} Busy={Format(rates.Busy)} ServerError={Format(rates.ServerError)} " +
                $"SaveThenError={Format(rates.SaveThenError)} LateResponse={Format(rates.LateResponse)}).");

        if (options.LateResponseDelaySeconds < 0)
            errors.Add("Simulator:LateResponseDelaySeconds must not be negative.");

        if (options.RetryAfterMinSeconds < 0 || options.RetryAfterMaxSeconds < options.RetryAfterMinSeconds)
            errors.Add("Simulator:RetryAfterMinSeconds/RetryAfterMaxSeconds must satisfy 0 <= min <= max.");

        return errors.Count == 0 ? ValidateOptionsResult.Success : ValidateOptionsResult.Fail(errors);
    }

    private static string Format(double value) => value.ToString(CultureInfo.InvariantCulture);
}
