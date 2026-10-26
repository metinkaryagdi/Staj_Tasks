using System.Net;
using System.Net.Http.Headers;
using System.Net.Sockets;
using InvoiceService.IntegrationTests.Support;

namespace InvoiceService.IntegrationTests;

/// <summary>
/// A service copy started while Keycloak is down cannot read Keycloak's issuer and keys: it refuses a valid token and says
/// why in its log. Once Keycloak is up again the same copy accepts tokens. The test takes down a Keycloak of its own, so
/// the other tests keep theirs. Keycloak comes back as a new container on the same port (Testcontainers does not get a
/// stopped Keycloak container ready again), so it signs with new keys: the token checked afterwards is a new one.
/// </summary>
public class KeycloakDownTests(PostgresFixture postgres, KeycloakFixture keycloak) : AuthTest(postgres, keycloak)
{
    private const string ReadPath = "/api/v1/invoices/summary";

    [Fact]
    public async Task A_service_started_while_Keycloak_is_down_refuses_tokens_with_a_log_line_and_accepts_them_once_it_is_back()
    {
        var port = FreePort();
        var before = KeycloakFixture.OnFixedPort(port);
        await before.InitializeAsync();
        var keycloakUrl = before.BaseUrl;
        var tokenFromBefore = await before.UserTokenAsync("operator");
        await before.DisposeAsync();

        var logs = new LogCollector();
        var settings = Settings();
        settings["Keycloak:BaseUrl"] = keycloakUrl;
        await using var service = new InvoiceServiceFactory(settings, logs);
        using var client = service.CreateClient();

        Assert.Equal(HttpStatusCode.Unauthorized, (await ReadAsync(client, tokenFromBefore)).StatusCode);
        Assert.Contains(logs.Lines, line =>
            line.StartsWith("Warning InvoiceService.Api.Auth: Token rejected: Keycloak cannot be reached"));

        var after = KeycloakFixture.OnFixedPort(port);
        try
        {
            await after.InitializeAsync();
            // The same service copy, not restarted.
            Assert.Equal(HttpStatusCode.OK, (await ReadAsync(client, await after.UserTokenAsync("operator"))).StatusCode);
        }
        finally
        {
            await after.DisposeAsync();
        }
    }

    private static Task<HttpResponseMessage> ReadAsync(HttpClient client, string token)
    {
        var request = new HttpRequestMessage(HttpMethod.Get, ReadPath);
        request.Headers.Authorization = new AuthenticationHeaderValue("Bearer", token);
        return client.SendAsync(request);
    }

    private static int FreePort()
    {
        var listener = new TcpListener(IPAddress.Loopback, 0);
        listener.Start();
        var port = ((IPEndPoint)listener.LocalEndpoint).Port;
        listener.Stop();
        return port;
    }
}
