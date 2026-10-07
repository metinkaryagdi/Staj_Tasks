using Microsoft.Extensions.Options;

namespace InvoiceService.Application.Reconciliation;

/// <summary>The "Reconciliation" settings. No defaults in code: a missing value stops the app at startup.</summary>
public sealed class ReconciliationOptions
{
    public const string SectionName = "Reconciliation";

    /// <summary>Minutes between scheduled runs; the first one starts this long after the service does.</summary>
    public int IntervalMinutes { get; set; }

    /// <summary>
    /// How far back a run looks: invoices created in the last this many hours. Invoices that are not final
    /// (Gönderildi, İşleme Alındı, Başarısız) are checked however old they are.
    /// </summary>
    public int LookbackHours { get; set; }

    /// <summary>
    /// An invoice that stays Gönderildi or İşleme Alındı longer than this many minutes is checked against the ERP.
    /// </summary>
    public int StuckAfterMinutes { get; set; }

    /// <summary><see cref="StuckAfterMinutes"/> as a time span; the one definition of "stuck" the planner and the summary share.</summary>
    public TimeSpan StuckAfter => TimeSpan.FromMinutes(StuckAfterMinutes);

    /// <summary>A waiting event for an invoice the service does not know is ignored after this many minutes.</summary>
    public int UnknownEventAfterMinutes { get; set; }

    /// <summary>
    /// A stuck invoice the ERP still has no decision for after this many minutes in its status is reported as
    /// <c>ERP Karar Vermedi</c>. At least <see cref="StuckAfterMinutes"/>: only stuck invoices are asked.
    /// </summary>
    public int NoDecisionAfterMinutes { get; set; }
}

public sealed class ReconciliationOptionsValidator(IConfiguration configuration) : IValidateOptions<ReconciliationOptions>
{
    /// <summary>One week: a chosen limit; with a longer wait between runs differences would stay unseen for too
    /// long.</summary>
    public const int MaxIntervalMinutes = 10_080;

    /// <summary>One year: a chosen limit; a longer window would read most of the database in every run.</summary>
    public const int MaxLookbackHours = 8_760;

    public static readonly string[] RequiredKeys =
    [
        nameof(ReconciliationOptions.IntervalMinutes), nameof(ReconciliationOptions.LookbackHours),
        nameof(ReconciliationOptions.StuckAfterMinutes), nameof(ReconciliationOptions.UnknownEventAfterMinutes),
        nameof(ReconciliationOptions.NoDecisionAfterMinutes)
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
                     (nameof(options.UnknownEventAfterMinutes), options.UnknownEventAfterMinutes),
                     (nameof(options.NoDecisionAfterMinutes), options.NoDecisionAfterMinutes)
                 })
        {
            if (value <= 0)
                errors.Add($"{ReconciliationOptions.SectionName}:{key} must be greater than 0 (was {value}).");
        }

        if (options.IntervalMinutes > MaxIntervalMinutes)
            errors.Add($"{ReconciliationOptions.SectionName}:IntervalMinutes must be at most {MaxIntervalMinutes} (was {options.IntervalMinutes}).");
        if (options.LookbackHours > MaxLookbackHours)
            errors.Add($"{ReconciliationOptions.SectionName}:LookbackHours must be at most {MaxLookbackHours} (was {options.LookbackHours}).");
        if (options.NoDecisionAfterMinutes < options.StuckAfterMinutes)
        {
            errors.Add($"{ReconciliationOptions.SectionName}:NoDecisionAfterMinutes must be at least StuckAfterMinutes " +
                       $"({options.StuckAfterMinutes}, was {options.NoDecisionAfterMinutes}): only stuck invoices are asked.");
        }

        return errors.Count == 0 ? ValidateOptionsResult.Success : ValidateOptionsResult.Fail(errors);
    }
}
