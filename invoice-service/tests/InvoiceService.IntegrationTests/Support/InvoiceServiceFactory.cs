using Microsoft.AspNetCore.Hosting;
using Microsoft.AspNetCore.Mvc.Testing;
using Microsoft.Extensions.Logging;

namespace InvoiceService.IntegrationTests.Support;

/// <summary>
/// The invoice service as Program.cs starts it (authentication, role rules, endpoints, workers), in memory. It reads the
/// settings it ships with; only the given keys are replaced (the test database, the fake ERP, the test Keycloak). When
/// <paramref name="logs"/> is given, the service's log lines are kept there too.
/// </summary>
public sealed class InvoiceServiceFactory(IReadOnlyDictionary<string, string?> settings, LogCollector? logs = null)
    : WebApplicationFactory<Program>
{
    protected override void ConfigureWebHost(IWebHostBuilder builder)
    {
        foreach (var (key, value) in settings)
            builder.UseSetting(key, value);
        if (logs is not null)
            builder.ConfigureLogging(logging => logging.AddProvider(logs));
    }
}
