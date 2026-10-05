using Microsoft.Extensions.Options;

namespace InvoiceService.Application.Reconciliation;

/// <summary>The "Reconciliation" settings. No defaults in code: a missing value stops the app at startup.</summary>
public sealed class ReconciliationOptions
{
    public const string SectionName = "Reconciliation";

    /// <summary>Minutes between scheduled runs; the first one starts this long after the service does.</summary>
    public int IntervalMinutes { get; set; }

    /// <summary>How far back a run looks: invoices created in the last this many hours.</summary>
    public int LookbackHours { get; set; }

    /// <summary>An invoice that stays Gönderildi or İşleme Alındı longer than this many minutes is checked against the ERP.</summary>
    public int StuckAfterMinutes { get; set; }

    /// <summary>A waiting event for an invoice the service does not know is ignored after this many minutes.</summary>
    public int UnknownEventAfterMinutes { get; set; }
}

public sealed class ReconciliationOptionsValidator(IConfiguration configuration) : IValidateOptions<ReconciliationOptions>
{
    public static readonly string[] RequiredKeys =
    [
        nameof(ReconciliationOptions.IntervalMinutes), nameof(ReconciliationOptions.LookbackHours),
        nameof(ReconciliationOptions.StuckAfterMinutes), nameof(ReconciliationOptions.UnknownEventAfterMinutes)
    ];

    public ValidateOptionsResult Validate(string? name, ReconciliationOptions options)
    {
        var errors = new List<string>();

        var section = configuration.GetSection(ReconciliationOptions.SectionName);
        foreach (var key in RequiredKeys)
        {
            if (string.IsNullOrWhiteSpace(section[key]))
                errors.Add($"{ReconciliationOptions.SectionName}:{key} is missing from the settings file.");
        }
        if (errors.Count > 0)
            return ValidateOptionsResult.Fail(errors);

        foreach (var (key, value) in new (string, int)[]
                 {
                     (nameof(options.IntervalMinutes), options.IntervalMinutes),
                     (nameof(options.LookbackHours), options.LookbackHours),
                     (nameof(options.StuckAfterMinutes), options.StuckAfterMinutes),
                     (nameof(options.UnknownEventAfterMinutes), options.UnknownEventAfterMinutes)
                 })
        {
            if (value <= 0)
                errors.Add($"{ReconciliationOptions.SectionName}:{key} must be greater than 0 (was {value}).");
        }

        return errors.Count == 0 ? ValidateOptionsResult.Success : ValidateOptionsResult.Fail(errors);
    }
}
