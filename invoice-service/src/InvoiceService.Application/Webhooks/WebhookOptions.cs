using System.Text;
using Microsoft.Extensions.Options;

namespace InvoiceService.Application.Webhooks;

/// <summary>
/// Bound from the "ErpWebhooks" section of appsettings.json. No defaults in code: a missing value stops the app at startup.
/// </summary>
public sealed class WebhookOptions
{
    public const string SectionName = "ErpWebhooks";

    /// <summary>Shared HMAC-SHA256 key; the ERP simulator signs with the same value.</summary>
    public string Secret { get; set; } = "";

    /// <summary>An event whose X-Erp-Timestamp is further than this from now (in the past or the future) gets 401.</summary>
    public int ToleranceSeconds { get; set; }

    /// <summary>A larger body gets 413 before its signature is computed.</summary>
    public int MaxBodyBytes { get; set; }

    /// <summary>Every event is answered within this time; if the work is not done by then, the answer is 503.</summary>
    public int ResponseBudgetMilliseconds { get; set; }

    /// <summary>How long the event waits for its invoice's row lock (PostgreSQL lock_timeout) before it gets 503.</summary>
    public int LockTimeoutMilliseconds { get; set; }
}

public sealed class WebhookOptionsValidator(IConfiguration configuration) : IValidateOptions<WebhookOptions>
{
    public static readonly string[] RequiredKeys =
        [nameof(WebhookOptions.Secret), nameof(WebhookOptions.ToleranceSeconds), nameof(WebhookOptions.MaxBodyBytes),
         nameof(WebhookOptions.ResponseBudgetMilliseconds), nameof(WebhookOptions.LockTimeoutMilliseconds)];

    /// <summary>The task: the service answers every event within 5 seconds.</summary>
    public const int TaskResponseLimitMilliseconds = 5000;

    /// <summary>HMAC-SHA256's own output size; a shorter key is easier to guess.</summary>
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

        var secretBytes = Encoding.UTF8.GetByteCount(options.Secret);
        if (secretBytes < MinSecretBytes)
            errors.Add($"ErpWebhooks:Secret must be at least {MinSecretBytes} bytes (was {secretBytes}).");
        if (options.ToleranceSeconds <= 0)
            errors.Add($"ErpWebhooks:ToleranceSeconds must be greater than 0 (was {options.ToleranceSeconds}).");
        if (options.MaxBodyBytes <= 0)
            errors.Add($"ErpWebhooks:MaxBodyBytes must be greater than 0 (was {options.MaxBodyBytes}).");
        if (options.ResponseBudgetMilliseconds <= 0 || options.ResponseBudgetMilliseconds >= TaskResponseLimitMilliseconds)
            errors.Add($"ErpWebhooks:ResponseBudgetMilliseconds must be greater than 0 and less than {TaskResponseLimitMilliseconds} " +
                $"(was {options.ResponseBudgetMilliseconds}).");
        if (options.LockTimeoutMilliseconds <= 0 || options.LockTimeoutMilliseconds >= options.ResponseBudgetMilliseconds)
            errors.Add("ErpWebhooks:LockTimeoutMilliseconds must be greater than 0 and less than ResponseBudgetMilliseconds " +
                $"(was {options.LockTimeoutMilliseconds}).");

        return errors.Count == 0 ? ValidateOptionsResult.Success : ValidateOptionsResult.Fail(errors);
    }
}
