using Microsoft.Extensions.Options;

namespace InvoiceService.Application.Metrics;

/// <summary>The "Metrics" settings. No defaults in code: a missing value stops the app at startup.</summary>
public sealed class MetricsOptions
{
    public const string SectionName = "Metrics";

    /// <summary>
    /// The values read from the database (queue, invoices by status, stuck, last completed reconciliation) are read again
    /// this many seconds after the end of the last reading; an export in between sends the last reading.
    /// </summary>
    public int DatabaseReadSeconds { get; set; }
}

public sealed class MetricsOptionsValidator(IConfiguration configuration) : IValidateOptions<MetricsOptions>
{
    public ValidateOptionsResult Validate(string? name, MetricsOptions options)
    {
        if (string.IsNullOrWhiteSpace(configuration.GetSection(MetricsOptions.SectionName)[nameof(MetricsOptions.DatabaseReadSeconds)]))
            return ValidateOptionsResult.Fail($"{MetricsOptions.SectionName}:{nameof(MetricsOptions.DatabaseReadSeconds)} is missing from the settings file.");

        return options.DatabaseReadSeconds <= 0
            ? ValidateOptionsResult.Fail($"Metrics:DatabaseReadSeconds must be greater than 0 (was {options.DatabaseReadSeconds}).")
            : ValidateOptionsResult.Success;
    }
}
