using Microsoft.Extensions.Configuration;

namespace InvoiceService.IntegrationTests.Support;

public static class TestSettings
{
    /// <summary>The ERP webhook secret in the tests; the shipped appsettings.json has none.</summary>
    public const string WebhookSecret = "test-only-erp-webhook-secret-at-least-32-bytes";

    /// <summary>
    /// The settings the service ships with (appsettings.json of the Api project, copied next to the test dll), pointed
    /// at the test database and the fake ERP.
    /// </summary>
    public static IConfiguration Build(string connectionString, string erpBaseUrl)
    {
        var values = new Dictionary<string, string?>
        {
            ["ConnectionStrings:InvoiceDb"] = connectionString,
            ["Erp:BaseUrl"] = erpBaseUrl,
            ["ErpWebhooks:Secret"] = WebhookSecret
        };

        return new ConfigurationBuilder()
            .AddJsonFile(Path.Combine(AppContext.BaseDirectory, "appsettings.json"))
            .AddInMemoryCollection(values)
            .Build();
    }
}
