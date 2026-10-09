using Microsoft.Extensions.Configuration;

namespace InvoiceService.IntegrationTests.Support;

public static class TestSettings
{
    /// <summary>
    /// The settings the service ships with (appsettings.json of the Api project, copied next to the test dll), pointed
    /// at the test database and the fake ERP.
    /// </summary>
    public static IConfiguration Build(string connectionString, string erpBaseUrl)
    {
        var values = new Dictionary<string, string?>
        {
            ["ConnectionStrings:InvoiceDb"] = connectionString,
            ["Erp:BaseUrl"] = erpBaseUrl
        };

        return new ConfigurationBuilder()
            .AddJsonFile(Path.Combine(AppContext.BaseDirectory, "appsettings.json"))
            .AddInMemoryCollection(values)
            .Build();
    }
}
