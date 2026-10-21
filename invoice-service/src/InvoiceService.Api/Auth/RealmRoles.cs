using System.Security.Claims;
using System.Text.Json;

namespace InvoiceService.Api.Auth;

/// <summary>
/// Keycloak puts the realm roles inside one claim, realm_access = {"roles": [...]}, while RequireRole looks for one role
/// claim per role. Copies each realm role into its own role claim.
/// </summary>
public static class RealmRoles
{
    public const string ClaimType = "realm_access";

    public static void AddTo(ClaimsIdentity identity)
    {
        var realmAccess = identity.FindFirst(ClaimType)?.Value;
        if (realmAccess is null)
            return;

        using var json = JsonDocument.Parse(realmAccess);
        if (!json.RootElement.TryGetProperty("roles", out var roles) || roles.ValueKind != JsonValueKind.Array)
            return;

        foreach (var role in roles.EnumerateArray())
        {
            if (role.GetString() is { } name)
                identity.AddClaim(new Claim(identity.RoleClaimType, name));
        }
    }
}