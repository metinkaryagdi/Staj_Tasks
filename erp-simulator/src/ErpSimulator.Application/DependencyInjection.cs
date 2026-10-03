using ErpSimulator.Application.Invoices;
using ErpSimulator.Application.Simulation;
using ErpSimulator.Application.Webhooks;
using Microsoft.Extensions.DependencyInjection;

namespace ErpSimulator.Application;

public static class DependencyInjection
{
    /// <summary>The settings (validated at startup), the seeded selectors and the use cases.</summary>
    public static IServiceCollection AddSimulatorApplication(this IServiceCollection services, IConfiguration configuration)
    {
        services.AddOptions<SimulatorOptions>()
            .Bind(configuration.GetSection(SimulatorOptions.SectionName))
            .ValidateOnStart();
        services.AddSingleton<IValidateOptions<SimulatorOptions>, SimulatorOptionsValidator>();
        services.AddSingleton<BehaviorSelector>();

        services.AddOptions<WebhookOptions>()
            .Bind(configuration.GetSection(WebhookOptions.SectionName))
            .ValidateOnStart();
        services.AddSingleton<IValidateOptions<WebhookOptions>, WebhookOptionsValidator>();
        services.AddSingleton(TimeProvider.System);
        services.AddSingleton<WebhookPlanner>();

        services.AddScoped<SubmitInvoiceHandler>();
        services.AddScoped<InvoiceLookup>();
        services.AddScoped<WebhookSender>();

        return services;
    }
}
