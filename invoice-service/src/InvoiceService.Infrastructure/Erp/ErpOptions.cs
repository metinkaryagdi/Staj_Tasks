using Microsoft.Extensions.Options;

namespace InvoiceService.Infrastructure.Erp;

/// <summary>
/// Bound from the "Erp" section of appsettings.json. There are no defaults in code:
/// every value must be present in the settings file, otherwise the app refuses to start.
/// </summary>
public sealed class ErpOptions
{
    public const string SectionName = "Erp";

    /// <summary>Base address of the ERP simulator, e.g. http://erp-simulator:8080 inside docker compose.</summary>
    public string BaseUrl { get; set; } = "";

    /// <summary>
    /// Timeout for one request to the ERP. HttpClient's own default is 100 seconds, which would keep the caller of
    /// POST /api/v1/invoices waiting far longer than any reasonable client timeout; we cut it at 10 seconds.
    /// </summary>
    public int TimeoutSeconds { get; set; }
}

public sealed class ErpOptionsValidator(IConfiguration configuration) : IValidateOptions<ErpOptions>
{
    public static readonly string[] RequiredKeys = ["BaseUrl", "TimeoutSeconds"];

    public ValidateOptionsResult Validate(string? name, ErpOptions options)
    {
        var errors = new List<string>();

        var section = configuration.GetSection(ErpOptions.SectionName);
        foreach (var key in RequiredKeys)
        {
            if (string.IsNullOrWhiteSpace(section[key]))
                errors.Add($"{ErpOptions.SectionName}:{key} is missing from the settings file.");
        }

        if (!Uri.TryCreate(options.BaseUrl, UriKind.Absolute, out var uri) || uri.Scheme is not ("http" or "https"))
            errors.Add($"Erp:BaseUrl must be an absolute http(s) URL (was '{options.BaseUrl}').");

        if (options.TimeoutSeconds <= 0)
            errors.Add($"Erp:TimeoutSeconds must be greater than 0 (was {options.TimeoutSeconds}).");

        return errors.Count == 0 ? ValidateOptionsResult.Success : ValidateOptionsResult.Fail(errors);
    }
}
