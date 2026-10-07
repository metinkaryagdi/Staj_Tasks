using InvoiceService.Api.Operators;

namespace InvoiceService.Api.Startup;

/// <summary>
/// Lets the operations screen, which runs in a browser at another address, call this API: the browser asks the
/// service first (an OPTIONS request) and only sends the real request if the answer names the screen's address.
/// </summary>
public static class CorsExtensions
{
    public const string SectionName = "Cors";
    public const string AllowedOriginsKey = "AllowedOrigins";
    public const string PolicyName = "OperationsUi";

    public static IServiceCollection AddOperationsUiCors(this IServiceCollection services, IConfiguration configuration)
    {
        var origins = configuration.GetSection($"{SectionName}:{AllowedOriginsKey}").Get<string[]>() ?? [];
        var errors = Validate(origins);
        if (errors.Count > 0)
            throw new InvalidOperationException(string.Join(" ", errors));

        services.AddCors(o => o.AddPolicy(PolicyName, policy => policy
            .WithOrigins(origins)
            .WithMethods("GET", "POST")
            .WithHeaders("Content-Type", OperatorHeader.Name)));
        return services;
    }

    /// <summary>What is wrong with the configured origins; empty when they can be used.</summary>
    public static IReadOnlyList<string> Validate(IReadOnlyCollection<string> origins)
    {
        if (origins.Count == 0)
            return [$"{SectionName}:{AllowedOriginsKey} is missing from the settings file or empty."];

        var errors = new List<string>();
        foreach (var origin in origins)
        {
            // An origin is scheme, host and port only: no path, no trailing slash, and "*" would let every site in.
            var valid = Uri.TryCreate(origin, UriKind.Absolute, out var uri)
                        && uri.Scheme is "http" or "https"
                        && origin == uri.GetLeftPart(UriPartial.Authority);
            if (!valid)
                errors.Add($"{SectionName}:{AllowedOriginsKey} has '{origin}', which is not an origin like http://localhost:5100.");
        }

        return errors;
    }
}
