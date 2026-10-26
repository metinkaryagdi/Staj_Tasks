using System.Net;
using System.Text.Json.Nodes;
using InvoiceService.IntegrationTests.Support;
using Microsoft.Extensions.Configuration;
using Microsoft.Extensions.DependencyInjection;
using Microsoft.IdentityModel.JsonWebTokens;

namespace InvoiceService.IntegrationTests;

/// <summary>
/// Tokens Keycloak really issued, made invalid in one way each, get 401 with the reason in WWW-Authenticate. The other
/// tokens are taken from copies of the test client (or of the realm) that differ only in what the test is about.
/// </summary>
public class InvalidTokenTests(PostgresFixture postgres, KeycloakFixture keycloak) : AuthTest(postgres, keycloak)
{
    private const string ReadPath = "/api/v1/invoices/summary";

    [Fact]
    public async Task A_token_whose_signature_is_changed_gets_401()
    {
        var token = await Keycloak.UserTokenAsync("operator");
        Assert.Equal(HttpStatusCode.OK, (await SendAsync(HttpMethod.Get, ReadPath, token)).StatusCode);

        // header.payload.signature: one character of the signature changed, the rest exactly as Keycloak signed it.
        var parts = token.Split('.');
        var signature = (parts[2][0] == 'A' ? "B" : "A") + parts[2][1..];
        var response = await SendAsync(HttpMethod.Get, ReadPath, $"{parts[0]}.{parts[1]}.{signature}");

        AssertUnauthorized(response, "signature");
    }

    [Fact]
    public async Task A_token_past_its_lifetime_and_the_tolerance_gets_401()
    {
        await Keycloak.AddTestClientAsync("fatura-test-kisa",
            client => client["attributes"] = new JsonObject { ["access.token.lifespan"] = "1" });
        Assert.Equal(HttpStatusCode.OK, (await SendAsync(HttpMethod.Get, "/health", null)).StatusCode);
        var token = await Keycloak.UserTokenAsync("operator", "fatura-test-kisa");
        var expires = new DateTimeOffset(new JsonWebToken(token).ValidTo, TimeSpan.Zero);
        // The tolerance the service ships with (appsettings.json, 30 s).
        var clockSkewSeconds = int.Parse(Service.Services.GetRequiredService<IConfiguration>()["Keycloak:ClockSkewSeconds"]!);

        // Expired, but within the tolerance: still accepted.
        await WaitUntilAsync(expires.AddSeconds(1));
        Assert.Equal(HttpStatusCode.OK, (await SendAsync(HttpMethod.Get, ReadPath, token)).StatusCode);

        await WaitUntilAsync(expires.AddSeconds(clockSkewSeconds + 1));
        AssertUnauthorized(await SendAsync(HttpMethod.Get, ReadPath, token), "expired");
    }

    [Fact]
    public async Task A_token_from_another_realm_gets_401()
    {
        await Keycloak.AddRealmCopyAsync("baska-realm");
        var token = await Keycloak.UserTokenAsync("operator", realm: "baska-realm");

        AssertUnauthorized(await SendAsync(HttpMethod.Get, ReadPath, token), "issuer");
    }

    [Fact]
    public async Task A_token_without_the_services_audience_gets_401()
    {
        await Keycloak.AddTestClientAsync("fatura-test-audiencesiz", client => client.Remove("protocolMappers"));
        var token = await Keycloak.UserTokenAsync("operator", "fatura-test-audiencesiz");

        AssertUnauthorized(await SendAsync(HttpMethod.Get, ReadPath, token), "audience");
    }

    private static void AssertUnauthorized(HttpResponseMessage response, string reason)
    {
        Assert.Equal(HttpStatusCode.Unauthorized, response.StatusCode);
        var header = response.Headers.WwwAuthenticate.ToString();
        Assert.True(header.Contains(reason, StringComparison.OrdinalIgnoreCase),
            $"Expected the reason to mention '{reason}'; WWW-Authenticate: {header}");
    }

    private static async Task WaitUntilAsync(DateTimeOffset moment)
    {
        var left = moment - DateTimeOffset.UtcNow;
        if (left > TimeSpan.Zero)
            await Task.Delay(left);
    }
}
