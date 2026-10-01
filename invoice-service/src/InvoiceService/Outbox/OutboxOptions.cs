using Microsoft.Extensions.Options;

namespace InvoiceService.Outbox;

/// <summary>
/// Bound from the "Outbox" section of appsettings.json. No defaults in code: a missing value stops the app at startup.
/// </summary>
public sealed class OutboxOptions
{
    public const string SectionName = "Outbox";

    /// <summary>How many ERP sends the worker runs at the same time (per service instance).</summary>
    public int MaxConcurrentSends { get; set; }
}

public sealed class OutboxOptionsValidator(IConfiguration configuration) : IValidateOptions<OutboxOptions>
{
    public ValidateOptionsResult Validate(string? name, OutboxOptions options)
    {
        if (string.IsNullOrWhiteSpace(configuration.GetSection(OutboxOptions.SectionName)[nameof(OutboxOptions.MaxConcurrentSends)]))
            return ValidateOptionsResult.Fail($"{OutboxOptions.SectionName}:MaxConcurrentSends is missing from the settings file.");

        return options.MaxConcurrentSends > 0
            ? ValidateOptionsResult.Success
            : ValidateOptionsResult.Fail($"Outbox:MaxConcurrentSends must be greater than 0 (was {options.MaxConcurrentSends}).");
    }
}
