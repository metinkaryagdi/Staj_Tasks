using InvoiceService.Application.Abstractions;
using InvoiceService.Infrastructure.Erp;
using InvoiceService.Infrastructure.Persistence;
using Microsoft.EntityFrameworkCore;
using Microsoft.Extensions.DependencyInjection;

namespace InvoiceService.Infrastructure;

public static class DependencyInjection
{
    /// <summary>The database, the stores that use it, and the way out to the ERP.</summary>
    public static IServiceCollection AddInvoiceInfrastructure(this IServiceCollection services, IConfiguration configuration)
    {
        services.AddOptions<ErpOptions>()
            .Bind(configuration.GetSection(ErpOptions.SectionName))
            .ValidateOnStart();
        services.AddSingleton<IValidateOptions<ErpOptions>, ErpOptionsValidator>();

        // Plain typed client on purpose: no resilience/retry handler, so each call makes exactly one HTTP request.
        // Retrying is decided by the outbox (RetryPolicy), not by the HTTP client.
        services.AddHttpClient<IErpGateway, ErpClient>((sp, http) =>
        {
            var erp = sp.GetRequiredService<IOptions<ErpOptions>>().Value;
            http.BaseAddress = new Uri(erp.BaseUrl);
            http.Timeout = TimeSpan.FromSeconds(erp.TimeoutSeconds);
        });

        services.AddDbContext<InvoiceDbContext>(o =>
            o.UseNpgsql(configuration.GetConnectionString("InvoiceDb")));
        services.AddScoped<IUnitOfWork, UnitOfWork>();
        services.AddScoped<IInvoiceStore, InvoiceStore>();
        services.AddScoped<IOutboxStore, OutboxStore>();
        services.AddScoped<IWebhookEventStore, WebhookEventStore>();
        services.AddSingleton<IDatabaseFailureClassifier, PostgresFailureClassifier>();

        return services;
    }
}
