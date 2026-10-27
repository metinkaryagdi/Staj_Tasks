using System.Net.Http.Headers;
using System.Net.Http.Json;
using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;
using Testcontainers.Keycloak;

namespace InvoiceService.IntegrationTests.Support;

/// <summary>
/// One Keycloak container for the authentication tests, started once, with the realm imported from the repository's
/// keycloak/fatura-realm.json. The fatura-test client (user name and password grant, kept out of the realm file) is added
/// the way manual-tests/keycloak/test-client-ekle.ps1 adds it, so the tests can take the test users' tokens.
/// </summary>
public sealed class KeycloakFixture : IAsyncLifetime
{
    // The order system client's secret in the test Keycloak.
    public const string OrderSystemSecret = "test-only-siparis-sistemi-secret";

    // fatura-realm.json reads these from the environment (${NAME}) when the realm is imported: the order system's secret and
    // the test users' passwords.
    private static readonly Dictionary<string, string> RealmEnvironment = new()
    {
        ["ORDER_SYSTEM_CLIENT_SECRET"] = OrderSystemSecret,
        ["TEST_IZLEYICI_PASSWORD"] = TestPassword("izleyici"),
        ["TEST_OPERATOR_PASSWORD"] = TestPassword("operator"),
        ["TEST_ROLSUZ_PASSWORD"] = TestPassword("rolsuz")
    };

    /// <summary>A test user's password in the test Keycloak.</summary>
    private static string TestPassword(string user) => $"test-only-{user}";

    private readonly KeycloakContainer _container;
    private readonly HttpClient _http = new();

    public KeycloakFixture() : this(null)
    {
    }

    private KeycloakFixture(int? hostPort)
    {
        var builder = new KeycloakBuilder("quay.io/keycloak/keycloak:26.8.1").WithRealm(FilePath("fatura-realm.json"))
            .WithEnvironment(RealmEnvironment);
        if (hostPort is { } port)
            builder = builder.WithPortBinding(port, 8080);
        _container = builder.Build();
    }

    /// <summary>
    /// A Keycloak of its own on a fixed port, for a test that takes Keycloak down and brings it up again: the issuer in the
    /// tokens contains the port, so the Keycloak that comes back must answer on the same one. The caller starts it
    /// (InitializeAsync) and disposes it.
    /// </summary>
    public static KeycloakFixture OnFixedPort(int hostPort) => new(hostPort);

    public string BaseUrl => _container.GetBaseAddress().TrimEnd('/');

    public async Task InitializeAsync()
    {
        await _container.StartAsync();
        await AddTestClientAsync("fatura-test");
    }

    public async Task DisposeAsync()
    {
        _http.Dispose();
        await _container.DisposeAsync();
    }

    /// <summary>
    /// Adds manual-tests' fatura-test client under the given id, changed as the test needs (a shorter token lifetime, no
    /// audience mapper …), so the other tests' client stays as it is.
    /// </summary>
    public async Task AddTestClientAsync(string clientId, Action<JsonObject>? change = null, string realm = "fatura")
    {
        var client = JsonNode.Parse(await File.ReadAllTextAsync(FilePath("fatura-test-client.json")))!.AsObject();
        client["clientId"] = clientId;
        change?.Invoke(client);
        await AdminAsync(HttpMethod.Post, $"/admin/realms/{realm}/clients", client.ToJsonString());
    }

    /// <summary>
    /// The repository's realm imported once more under another name, with the test client: the same roles, users and
    /// audience mapper, but its own signing keys and issuer.
    /// </summary>
    public async Task AddRealmCopyAsync(string realm)
    {
        // The admin API does not replace ${...} placeholders the way the import at start does.
        var realmFile = await File.ReadAllTextAsync(FilePath("fatura-realm.json"));
        foreach (var (name, value) in RealmEnvironment)
            realmFile = realmFile.Replace("${" + name + "}", value);
        var copy = JsonNode.Parse(realmFile)!.AsObject();
        copy["realm"] = realm;
        await AdminAsync(HttpMethod.Post, "/admin/realms", copy.ToJsonString());
        await AddTestClientAsync("fatura-test", realm: realm);
    }

    /// <summary>
    /// Keycloak changes the realm's signing key: a new RSA key with a higher priority signs from now on and the one the
    /// realm was created with is removed, so it is no longer in the realm's JWKS.
    /// </summary>
    public async Task ReplaceSigningKeyAsync(string realm)
    {
        var realmJson = await (await AdminAsync(HttpMethod.Get, $"/admin/realms/{realm}")).Content.ReadFromJsonAsync<JsonElement>();
        var providers = await (await AdminAsync(HttpMethod.Get,
            $"/admin/realms/{realm}/components?type=org.keycloak.keys.KeyProvider")).Content.ReadFromJsonAsync<JsonElement>();
        var oldKey = providers.EnumerateArray().Single(p => p.GetProperty("providerId").GetString() == "rsa-generated")
            .GetProperty("id").GetString();

        await AdminAsync(HttpMethod.Post, $"/admin/realms/{realm}/components", JsonSerializer.Serialize(new
        {
            name = "rsa-yeni",
            providerId = "rsa-generated",
            providerType = "org.keycloak.keys.KeyProvider",
            parentId = realmJson.GetProperty("id").GetString(),
            config = new Dictionary<string, string[]> { ["priority"] = ["200"], ["algorithm"] = ["RS256"] }
        }));
        await AdminAsync(HttpMethod.Delete, $"/admin/realms/{realm}/components/{oldKey}");
    }

    // The realm's test users (izleyici, operator, rolsuz), with the passwords this Keycloak was given.
    public Task<string> UserTokenAsync(string user, string clientId = "fatura-test", string realm = "fatura") => TokenAsync(realm, new()
    {
        ["grant_type"] = "password",
        ["client_id"] = clientId,
        ["username"] = user,
        ["password"] = TestPassword(user)
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

    private static string FilePath(string name) => Path.Combine(AppContext.BaseDirectory, "keycloak", name);
}

/// <summary>The authentication tests: the whole service over HTTP, with its own database and the real Keycloak.</summary>
[CollectionDefinition(Name)]
public sealed class AuthCollection : ICollectionFixture<PostgresFixture>, ICollectionFixture<KeycloakFixture>
{
    public const string Name = "Auth";
}