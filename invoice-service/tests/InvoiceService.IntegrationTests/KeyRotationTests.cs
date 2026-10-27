using System.Net;
using InvoiceService.IntegrationTests.Support;
using Microsoft.IdentityModel.JsonWebTokens;

namespace InvoiceService.IntegrationTests;

/// <summary>
/// Keycloak changes its signing key while the service runs: a token signed with the new key is accepted and one signed
/// with the removed key is refused, by the same service copy. The test has a realm of its own, so the other tests keep
/// their keys.
/// </summary>
public class KeyRotationTests(PostgresFixture postgres, KeycloakFixture keycloak) : AuthTest(postgres, keycloak)
{
    private const string Realm = "rotasyon-realm";

    protected override Dictionary<string, string?> Settings()
    {
        var settings = base.Settings();
        settings["Keycloak:Realm"] = Realm;
        return settings;
    }

    [Fact]
    public async Task After_the_signing_key_changes_the_new_key_is_accepted_and_the_removed_one_refused_without_a_restart()
    {
        await Keycloak.AddRealmCopyAsync(Realm);
        var oldToken = await Keycloak.UserTokenAsync("operator", realm: Realm);
        Assert.Equal(HttpStatusCode.OK, (await ReadAsync(oldToken)).StatusCode);

        await Keycloak.ReplaceSigningKeyAsync(Realm);
        var newToken = await Keycloak.UserTokenAsync("operator", realm: Realm);
        Assert.NotEqual(new JsonWebToken(oldToken).Kid, new JsonWebToken(newToken).Kid);

        // The service reads Keycloak's keys again when it sees a key it does not know; the request that makes it read them
        // is still refused, the next ones are accepted.
        await Eventually.WaitUntilAsync(async () => (await ReadAsync(newToken)).StatusCode == HttpStatusCode.OK,
            "the token signed with the new key is accepted", limitSeconds: 10);
        Assert.Equal(HttpStatusCode.Unauthorized, (await ReadAsync(oldToken)).StatusCode);
    }

    private Task<HttpResponseMessage> ReadAsync(string token) => SendAsync(HttpMethod.Get, "/api/v1/invoices/summary", token);
}
