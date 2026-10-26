using System.Net.Http.Headers;
using System.Net.Http.Json;
using System.Text;
using System.Text.Json;
using Testcontainers.Keycloak;

namespace InvoiceService.IntegrationTests.Support;

/// <summary>
/// One Keycloak container for the authentication tests, started once, with the realm imported from the repository's
/// keycloak/fatura-realm.json. The fatura-test client (user name and password grant, kept out of the realm file) is added
/// the way manual-tests/keycloak/test-client-ekle.ps1 adds it, so the tests can take the test users' tokens.
/// </summary>
public sealed class KeycloakFixture : IAsyncLifetime
{
    // The order system client's secret in fatura-realm.json (local and test use only).
    public const string OrderSystemSecret = "dev-only-siparis-sistemi-secret-do-not-use-in-production";

    private readonly KeycloakContainer _container = new KeycloakBuilder("quay.io/keycloak/keycloak:26.8.1")
        .WithRealm(Path.Combine(AppContext.BaseDirectory, "keycloak", "fatura-realm.json"))
        .Build();

    private readonly HttpClient _http = new();

    public string BaseUrl => _container.GetBaseAddress().TrimEnd('/');

    public async Task InitializeAsync()
    {
        await _container.StartAsync();
        var testClient = await File.ReadAllTextAsync(Path.Combine(AppContext.BaseDirectory, "keycloak", "fatura-test-client.json"));
        await AdminAsync(HttpMethod.Post, "/admin/realms/fatura/clients", testClient);
    }

    public async Task DisposeAsync()
    {
        _http.Dispose();
        await _container.DisposeAsync();
    }

    // The realm's test users (izleyici, operator, rolsuz); each password is the user name followed by 123.
    public Task<string> UserTokenAsync(string user) => TokenAsync("fatura", new()
    {
        ["grant_type"] = "password",
        ["client_id"] = "fatura-test",
        ["username"] = user,
        ["password"] = $"{user}123"
    });

    public Task<string> OrderSystemTokenAsync() => TokenAsync("fatura", new()
    {
        ["grant_type"] = "client_credentials",
        ["client_id"] = "siparis-sistemi",
        ["client_secret"] = OrderSystemSecret
    });

    // Keycloak's admin API, with Testcontainers' default administrator (admin / admin).
    public async Task<HttpResponseMessage> AdminAsync(HttpMethod method, string path, string? json = null)
    {
        var adminToken = await TokenAsync("master", new()
        {
            ["grant_type"] = "password",
            ["client_id"] = "admin-cli",
            ["username"] = "admin",
            ["password"] = "admin"
        });

        var request = new HttpRequestMessage(method, BaseUrl + path);
        request.Headers.Authorization = new AuthenticationHeaderValue("Bearer", adminToken);
        if (json is not null)
            request.Content = new StringContent(json, Encoding.UTF8, "application/json");

        var response = await _http.SendAsync(request);
        response.EnsureSuccessStatusCode();
        return response;
    }

    private async Task<string> TokenAsync(string realm, Dictionary<string, string> form)
    {
        var response = await _http.PostAsync($"{BaseUrl}/realms/{realm}/protocol/openid-connect/token",
            new FormUrlEncodedContent(form));
        response.EnsureSuccessStatusCode();
        var body = await response.Content.ReadFromJsonAsync<JsonElement>();
        return body.GetProperty("access_token").GetString()!;
    }
}

/// <summary>The authentication tests: the whole service over HTTP, with its own database and the real Keycloak.</summary>
[CollectionDefinition(Name)]
public sealed class AuthCollection : ICollectionFixture<PostgresFixture>, ICollectionFixture<KeycloakFixture>
{
    public const string Name = "Auth";
}