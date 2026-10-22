using System.Security.Claims;
using Microsoft.AspNetCore.Authentication.JwtBearer;
using Microsoft.AspNetCore.Authorization;

namespace InvoiceService.Api.Auth;

/// <summary>
/// JWT authentication against Keycloak and the role rules of the endpoints. The service checks every token itself:
/// signature (with the realm's published keys, JWKS), issuer, audience and lifetime.
/// </summary>
public static class AuthExtensions
{
    /// <summary>
    /// How long after its expiry a token is still accepted, for clocks that differ a little. The default is 5 minutes, which
    /// would keep an expired token working that long.
    /// </summary>
    public static readonly TimeSpan ClockSkew = TimeSpan.FromSeconds(30);

    public static IServiceCollection AddKeycloakAuth(this IServiceCollection services, IConfiguration configuration)
    {
        var settings = configuration.GetSection(KeycloakSettings.SectionName).Get<KeycloakSettings>() ?? new KeycloakSettings();
        var errors = settings.Validate();
        if (errors.Count > 0)
            throw new InvalidOperationException(string.Join(" ", errors));

        services.AddAuthentication(JwtBearerDefaults.AuthenticationScheme)
            .AddJwtBearer(options =>
            {
                // JwtBearer's defaults check the signature against the keys at the Authority's JWKS, the issuer named in its
                // discovery document, the audience and the lifetime; none of them is turned off here.
                options.Authority = settings.Authority;
                options.Audience = settings.Audience;
                // Keycloak runs on plain HTTP on the developer's machine and in docker compose.
                options.RequireHttpsMetadata = false;
                options.TokenValidationParameters.ClockSkew = ClockSkew;
                options.Events = new JwtBearerEvents
                {
                    OnTokenValidated = context =>
                    {
                        RealmRoles.AddTo((ClaimsIdentity)context.Principal!.Identity!);
                        return Task.CompletedTask;
                    }
                };
            });

        services.AddAuthorization(options =>
        {
            options.AddPolicy(Policies.Read, p => p.RequireRole(Roles.Viewer, Roles.Operator));
            options.AddPolicy(Policies.Intervene, p => p.RequireRole(Roles.Operator));
            options.AddPolicy(Policies.CreateInvoice, p => p.RequireRole(Roles.InvoiceCreator));
            // Every endpoint needs a valid token unless it says otherwise; only the ERP webhook does (it has its own HMAC
            // signature). A new endpoint is protected even if its rule is forgotten.
            options.FallbackPolicy = new AuthorizationPolicyBuilder().RequireAuthenticatedUser().Build();
        });
        return services;
    }
}