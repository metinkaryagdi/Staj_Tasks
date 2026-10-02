using System.Text;
using Microsoft.Extensions.Options;

namespace ErpSimulator.Webhooks;

/// <summary>
/// Bound from the "Webhooks" section of appsettings.json. No defaults in code: a missing value stops the app at startup.
/// </summary>
public sealed class WebhookOptions
{
    public const string SectionName = "Webhooks";

    /// <summary>
    /// Off: a saved invoice gets no events at all. For tests that send hand-made events and must not get the
    /// simulator's own ones in between; the task's behavior is on.
    /// </summary>
    public bool Enabled { get; set; }

    /// <summary>The invoice service's POST /api/v1/erp-webhooks address.</summary>
    public string TargetUrl { get; set; } = "";

    /// <summary>Shared HMAC-SHA256 key; the invoice service checks with the same value.</summary>
    public string Secret { get; set; } = "";

    /// <summary>A send without a 2xx answer within this time counts as failed.</summary>
    public int TimeoutSeconds { get; set; }

    /// <summary>Wait before each retry; its length is the number of retries (task: 5, 10, 20, 40, 80).</summary>
    public int[] RetryDelaysSeconds { get; set; } = [];

    /// <summary>invoice.received is due this long after the invoice is saved (random in [min, max]).</summary>
    public int FirstEventMinSeconds { get; set; }
    public int FirstEventMaxSeconds { get; set; }

    /// <summary>The decision is due this long after invoice.received (random in [min, max]).</summary>
    public int SecondEventMinSeconds { get; set; }
    public int SecondEventMaxSeconds { get; set; }

    /// <summary>Chance of invoice.approved, in percent; the rest is invoice.rejected.</summary>
    public double ApprovalRate { get; set; }

    /// <summary>A rejected event carries one of these, picked at random.</summary>
    public string[] RejectReasons { get; set; } = [];

    /// <summary>At most this many sends run at the same time.</summary>
    public int MaxConcurrentSends { get; set; }

    /// <summary>How often the dispatcher looks for due events, in milliseconds.</summary>
    public int PollMilliseconds { get; set; }

    /// <summary>The deliberate problems; each rate is drawn independently of the others.</summary>
    public WebhookProblems Problems { get; set; } = new();
}

/// <summary>Rates in percent, each drawn on its own (they do not have to add up to anything).</summary>
public sealed class WebhookProblems
{
    /// <summary>Per event: the event is sent twice with the same event_id.</summary>
    public double DuplicateRate { get; set; }

    /// <summary>Per invoice: the decision is sent before invoice.received.</summary>
    public double OrderMixRate { get; set; }

    /// <summary>Per invoice: the decision is never sent.</summary>
    public double LostDecisionRate { get; set; }

    /// <summary>Per invoice: a decision with a wrong signature is sent for it.</summary>
    public double FakeRate { get; set; }

    /// <summary>Per invoice: one of its events is sent again later with an old timestamp and a signature valid for it.</summary>
    public double ReplayRate { get; set; }

    /// <summary>How old the replayed event's timestamp is, in seconds (task: 10 minutes).</summary>
    public int ReplayAgeSeconds { get; set; }
}

public sealed class WebhookOptionsValidator(IConfiguration configuration) : IValidateOptions<WebhookOptions>
{
    public static readonly string[] RequiredKeys =
    [
        "Enabled", "TargetUrl", "Secret", "TimeoutSeconds", "RetryDelaysSeconds:0", "FirstEventMinSeconds", "FirstEventMaxSeconds",
        "SecondEventMinSeconds", "SecondEventMaxSeconds", "ApprovalRate", "RejectReasons:0", "MaxConcurrentSends",
        "PollMilliseconds", "Problems:DuplicateRate", "Problems:OrderMixRate", "Problems:LostDecisionRate",
        "Problems:FakeRate", "Problems:ReplayRate", "Problems:ReplayAgeSeconds"
    ];

    public const int MinSecretBytes = 32;

    public ValidateOptionsResult Validate(string? name, WebhookOptions options)
    {
        var errors = new List<string>();

        var section = configuration.GetSection(WebhookOptions.SectionName);
        foreach (var key in RequiredKeys)
        {
            if (string.IsNullOrWhiteSpace(section[key]))
                errors.Add($"{WebhookOptions.SectionName}:{key} is missing from the settings file.");
        }
        if (errors.Count > 0)
            return ValidateOptionsResult.Fail(errors);

        if (!Uri.TryCreate(options.TargetUrl, UriKind.Absolute, out var uri) || uri.Scheme is not ("http" or "https"))
            errors.Add($"Webhooks:TargetUrl must be an absolute http(s) URL (was '{options.TargetUrl}').");
        if (Encoding.UTF8.GetByteCount(options.Secret) < MinSecretBytes)
            errors.Add($"Webhooks:Secret must be at least {MinSecretBytes} bytes.");
        if (options.TimeoutSeconds <= 0)
            errors.Add($"Webhooks:TimeoutSeconds must be greater than 0 (was {options.TimeoutSeconds}).");
        if (options.RetryDelaysSeconds.Any(d => d <= 0))
            errors.Add("Webhooks:RetryDelaysSeconds must all be greater than 0.");
        if (options.FirstEventMinSeconds < 0 || options.FirstEventMaxSeconds < options.FirstEventMinSeconds)
            errors.Add("Webhooks:FirstEventMinSeconds/FirstEventMaxSeconds must satisfy 0 <= min <= max.");
        if (options.SecondEventMinSeconds < 0 || options.SecondEventMaxSeconds < options.SecondEventMinSeconds)
            errors.Add("Webhooks:SecondEventMinSeconds/SecondEventMaxSeconds must satisfy 0 <= min <= max.");
        if (!double.IsFinite(options.ApprovalRate) || options.ApprovalRate is < 0 or > 100)
            errors.Add($"Webhooks:ApprovalRate must be a number between 0 and 100 (was {options.ApprovalRate}).");
        if (options.RejectReasons.Any(string.IsNullOrWhiteSpace))
            errors.Add("Webhooks:RejectReasons must not contain empty values.");
        if (options.MaxConcurrentSends <= 0)
            errors.Add($"Webhooks:MaxConcurrentSends must be greater than 0 (was {options.MaxConcurrentSends}).");
        if (options.PollMilliseconds <= 0)
            errors.Add($"Webhooks:PollMilliseconds must be greater than 0 (was {options.PollMilliseconds}).");

        var p = options.Problems;
        foreach (var (rateName, value) in new[]
                 {
                     (nameof(p.DuplicateRate), p.DuplicateRate), (nameof(p.OrderMixRate), p.OrderMixRate),
                     (nameof(p.LostDecisionRate), p.LostDecisionRate), (nameof(p.FakeRate), p.FakeRate),
                     (nameof(p.ReplayRate), p.ReplayRate)
                 })
        {
            if (!double.IsFinite(value) || value is < 0 or > 100)
                errors.Add($"Webhooks:Problems:{rateName} must be a number between 0 and 100 (was {value}).");
        }
        if (p.ReplayAgeSeconds <= 0)
            errors.Add($"Webhooks:Problems:ReplayAgeSeconds must be greater than 0 (was {p.ReplayAgeSeconds}).");

        return errors.Count == 0 ? ValidateOptionsResult.Success : ValidateOptionsResult.Fail(errors);
    }
}
