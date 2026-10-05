using ErpSimulator.Application.Abstractions;
using ErpSimulator.Infrastructure.Persistence;
using ErpSimulator.Infrastructure.Webhooks;
using Microsoft.EntityFrameworkCore;
using Microsoft.Extensions.DependencyInjection;

namespace ErpSimulator.Infrastructure;

public static class DependencyInjection
{
    /// <summary>The database, the stores that use it, and the way out to the invoice service.</summary>
    public static IServiceCollection AddSimulatorInfrastructure(this IServiceCollection services, IConfiguration configuration)
    {
        // The 5 s limit is applied per send by the transport (its own token), so the client itself never cuts a send
        // short. Named "webhooks" as before, so the HttpClient log lines keep their category.
        services.AddHttpClient<IWebhookTransport, HttpWebhookTransport>(
            HttpWebhookTransport.HttpClientName, http => http.Timeout = Timeout.InfiniteTimeSpan);

        services.AddDbContext<ErpDbContext>(o =>
            o.UseNpgsql(configuration.GetConnectionString("ErpDb")));
        services.AddScoped<IUnitOfWork, UnitOfWork>();
        services.AddScoped<IErpInvoiceStore, ErpInvoiceStore>();
        services.AddScoped<IWebhookDeliveryStore, WebhookDeliveryStore>();

        return services;
    }
}
