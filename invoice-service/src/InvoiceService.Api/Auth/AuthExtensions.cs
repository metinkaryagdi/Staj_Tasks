using System.Security.Claims;
using Microsoft.AspNetCore.Authentication.JwtBearer;
using Microsoft.AspNetCore.Authorization;
using Microsoft.IdentityModel.Tokens;

namespace InvoiceService.Api.Auth;

/// <summary>
/// JWT authentication against Keycloak and the role rules of the endpoints. The service checks every token itself:
/// signature (with the realm's published keys, JWKS), issuer, audience and lifetime.
/// </summary>
public static class AuthExtensions
{
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
                // JwtBearer's default would accept an expired token for 5 more minutes; the settings file says how long.
                options.TokenValidationParameters.ClockSkew = TimeSpan.FromSeconds(settings.ClockSkewSeconds!.Value);
                // A key Keycloak no longer publishes stays in the service's list until the list is read again; the library's
                // default reads it every 12 hours. A key already in the list does not make the service read it sooner.
                options.AutomaticRefreshInterval = TimeSpan.FromMinutes(settings.JwksRefreshMinutes!.Value);
                // Claims keep the names they have in the token: by default "sub" would be renamed to the long
                // NameIdentifier type and FindFirst("sub") would find nothing.
                options.MapInboundClaims = false;
                // Keycloak runs on plain HTTP on the developer's machine and in docker compose.
                options.RequireHttpsMetadata = false;
                options.Events = new JwtBearerEvents
                {
                    OnTokenValidated = context =>
                    {
                        RealmRoles.AddTo((ClaimsIdentity)context.Principal!.Identity!);
                        return Task.CompletedTask;
                    },
                    // When the service could not read Keycloak's discovery document (Keycloak down when the service
                    // started), it knows no issuer and no keys: every token fails as "issuer is invalid" and JwtBearer
                    // logs this only at Information. Asking for the configuration again tells the two cases apart; a
                    // token from another issuer while Keycloak is reachable is not logged here.
                    OnAuthenticationFailed = async context =>
                    {
                        if (context.Exception is not SecurityTokenInvalidIssuerException)
                            return;

                        try
                        {
                            await context.Options.ConfigurationManager!.GetConfigurationAsync(context.HttpContext.RequestAborted);
                        }
                        catch (Exception ex)
                        {
                            var logger = context.HttpContext.RequestServices.GetRequiredService<ILoggerFactory>()
                                .CreateLogger("InvoiceService.Api.Auth");
                            logger.LogWarning(
                                "Token rejected: Keycloak cannot be reached at {Authority}, so its signing keys are not known: {Error}",
                                settings.Authority, ex.GetBaseException().Message);
                        }
                    }
                };
            });

        // A token signed with a key Keycloak no longer publishes is refused. By default the library retries a token whose key
        // it cannot find with the keys it read earlier ("last known good"), so a key removed from Keycloak kept working.
        // This runs after JwtBearer has created its configuration manager.
        services.PostConfigure<JwtBearerOptions>(JwtBearerDefaults.AuthenticationScheme, options =>
            ((BaseConfigurationManager)options.ConfigurationManager!).UseLastKnownGoodConfiguration = false);

        services.AddAuthorization(options =>
        {
            options.AddPolicy(Policies.Read, p => p.RequireRole(Roles.Viewer, Roles.Operator));
            options.AddPolicy(Policies.Intervene, p => p.RequireRole(Roles.Operator));
            options.AddPolicy(Policies.CreateInvoice, p => p.RequireRole(Roles.InvoiceCreator));
            // Every endpoint needs a valid token unless it says otherwise; only the ERP webhook (it has its own HMAC
            // signature) and /health do. A new endpoint is protected even if its rule is forgotten.
            options.FallbackPolicy = new AuthorizationPolicyBuilder().RequireAuthenticatedUser().Build();
        });
        return services;
    }
}