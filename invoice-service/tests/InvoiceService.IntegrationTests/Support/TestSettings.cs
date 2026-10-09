using Microsoft.Extensions.Configuration;

namespace InvoiceService.IntegrationTests.Support;

public static class TestSettings
{
    /// <summary>
    /// The settings the service ships with (appsettings.json of the Api project, copied next to the test dll), pointed
    /// at the test database and the fake ERP. <paramref name="overrides"/> change single settings for one test.
    /// </summary>
    public static IConfiguration Build(string connectionString, string erpBaseUrl, IReadOnlyDictionary<string, string?>? overrides = null)
    {
        var values = new Dictionary<string, string?>
        {
            ["ConnectionStrings:InvoiceDb"] = connectionString,
            ["Erp:BaseUrl"] = erpBaseUrl
        };
        foreach (var (key, value) in overrides ?? new Dictionary<string, string?>())
            values[key] = value;

        return new ConfigurationBuilder()
            .AddJsonFile(Path.Combine(AppContext.BaseDirectory, "appsettings.json"))
            .AddInMemoryCollection(values)
            .Build();
    }
}
