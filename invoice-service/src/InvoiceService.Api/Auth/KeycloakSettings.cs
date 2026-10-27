using Microsoft.IdentityModel.Tokens;

namespace InvoiceService.Api.Auth;

/// <summary>
/// The "Keycloak" section of appsettings.json: where the tokens come from and which audience they must carry. There are
/// no defaults in code; a missing or invalid value stops the service at start.
/// </summary>
public sealed class KeycloakSettings
{
    public const string SectionName = "Keycloak";

    /// <summary>The shortest key refresh the library accepts; a shorter one would throw when JwtBearer is set up.</summary>
    public static readonly int MinimumJwksRefreshMinutes =
        (int)BaseConfigurationManager.MinimumAutomaticRefreshInterval.TotalMinutes;

    /// <summary>Keycloak's address, e.g. http://keycloak:8080 inside docker compose.</summary>
    public string BaseUrl { get; set; } = "";

    /// <summary>The realm that issues the tokens.</summary>
    public string Realm { get; set; } = "";

    /// <summary>The aud value a token must carry to be accepted by this service.</summary>
    public string Audience { get; set; } = "";

    /// <summary>How long an expired token is still accepted, seconds (allows for clocks that differ a little).</summary>
    public int? ClockSkewSeconds { get; set; }

    /// <summary>
    /// How often the service reads Keycloak's signing keys (JWKS) again, minutes. A key removed from Keycloak is accepted
    /// until the next read; the library does not allow less than 5 minutes.
    /// </summary>
    public int? JwksRefreshMinutes { get; set; }

    /// <summary>The realm's address; the discovery document and the signing keys (JWKS) are read from here.</summary>
    public string Authority => $"{BaseUrl.TrimEnd('/')}/realms/{Realm}";

    /// <summary>What is wrong with the settings; empty when they can be used.</summary>
    public IReadOnlyList<string> Validate()
    {
        var errors = new List<string>();
        if (!Uri.TryCreate(BaseUrl, UriKind.Absolute, out var uri) || uri.Scheme is not ("http" or "https"))
            errors.Add($"{SectionName}:BaseUrl must be an absolute http(s) URL (was '{BaseUrl}').");
        if (string.IsNullOrWhiteSpace(Realm))
            errors.Add($"{SectionName}:Realm is missing from the settings file.");
        if (string.IsNullOrWhiteSpace(Audience))
            errors.Add($"{SectionName}:Audience is missing from the settings file.");
        if (ClockSkewSeconds is null)
            errors.Add($"{SectionName}:ClockSkewSeconds is missing from the settings file.");
        else if (ClockSkewSeconds < 0)
            errors.Add($"{SectionName}:ClockSkewSeconds must be 0 or more (was {ClockSkewSeconds}).");
        if (JwksRefreshMinutes is null)
            errors.Add($"{SectionName}:JwksRefreshMinutes is missing from the settings file.");
        else if (JwksRefreshMinutes < MinimumJwksRefreshMinutes)
            errors.Add($"{SectionName}:JwksRefreshMinutes must be {MinimumJwksRefreshMinutes} or more (was {JwksRefreshMinutes}).");
        return errors;
    }
}