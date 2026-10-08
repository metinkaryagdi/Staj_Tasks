using Microsoft.Extensions.Options;

namespace ErpSimulator.Application.Simulation;

/// <summary>
/// Bound from the "RateLimit" section: how many invoice submissions the simulator accepts per second, shared by every
/// client. No default in code: a missing value stops the app at startup.
/// </summary>
public sealed class RateLimitOptions
{
    public const string SectionName = "RateLimit";

    /// <summary>Requests accepted per second; the bucket holds this many tokens and is refilled once a second.</summary>
    public int PermitsPerSecond { get; set; }
}

public sealed class RateLimitOptionsValidator(IConfiguration configuration) : IValidateOptions<RateLimitOptions>
{
    public ValidateOptionsResult Validate(string? name, RateLimitOptions options)
    {
        var key = $"{RateLimitOptions.SectionName}:{nameof(RateLimitOptions.PermitsPerSecond)}";
        if (string.IsNullOrWhiteSpace(configuration[key]))
            return ValidateOptionsResult.Fail($"{key} is missing from the settings file.");

        return options.PermitsPerSecond > 0
            ? ValidateOptionsResult.Success
            : ValidateOptionsResult.Fail($"{key} must be greater than 0 (was {options.PermitsPerSecond}).");
    }
}
