using System.Net.Http.Headers;
using System.Net.Http.Json;

namespace InvoiceService.IntegrationTests.Support;

/// <summary>
/// What every authentication test starts from: its own empty database, its own fake ERP and a copy of the service that
/// checks tokens against the test Keycloak. The service starts on the first request.
/// </summary>
[Collection(AuthCollection.Name)]
public abstract class AuthTest(PostgresFixture postgres, KeycloakFixture keycloak) : IAsyncLifetime
{
    private string _databaseName = "";

    protected KeycloakFixture Keycloak => keycloak;
    protected FakeErp Erp { get; private set; } = null!;
    protected InvoiceServiceFactory Service { get; private set; } = null!;
    protected string ConnectionString { get; private set; } = "";

    public async Task InitializeAsync()
    {
        (_databaseName, ConnectionString) = await postgres.CreateDatabaseAsync();
        Erp = await FakeErp.StartAsync();
        Service = new InvoiceServiceFactory(Settings());
    }

    public async Task DisposeAsync()
    {
        await Service.DisposeAsync();
        await Erp.DisposeAsync();
        await postgres.DropDatabaseAsync(_databaseName);
    }

    /// <summary>The settings replaced in the service's appsettings.json; a test class can add its own.</summary>
    protected virtual Dictionary<string, string?> Settings() => new()
    {
        ["ConnectionStrings:InvoiceDb"] = ConnectionString,
        ["Erp:BaseUrl"] = Erp.BaseUrl,
        ["Keycloak:BaseUrl"] = keycloak.BaseUrl,
        // No Collector runs in the tests: the exporters would wait about 4 s at every shutdown trying to send.
        ["OTEL_SDK_DISABLED"] = "true"
    };

    /// <summary>Sends a request to the service, with the token as a Bearer header when one is given.</summary>
    protected async Task<HttpResponseMessage> SendAsync(HttpMethod method, string path, string? token, object? body = null)
    {
        using var client = Service.CreateClient();
        var request = new HttpRequestMessage(method, path);
        if (token is not null)
            request.Headers.Authorization = new AuthenticationHeaderValue("Bearer", token);
        if (body is not null)
            request.Content = JsonContent.Create(body);
        return await client.SendAsync(request);
    }
}
