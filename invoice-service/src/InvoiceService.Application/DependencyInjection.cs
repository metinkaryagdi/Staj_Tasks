using InvoiceService.Application.Invoices;
using InvoiceService.Application.Outbox;
using InvoiceService.Application.Webhooks;
using Microsoft.Extensions.DependencyInjection;

namespace InvoiceService.Application;

public static class DependencyInjection
{
    /// <summary>The settings (validated at startup), the retry policy and the use cases.</summary>
    public static IServiceCollection AddInvoiceApplication(this IServiceCollection services, IConfiguration configuration)
    {
        services.AddOptions<OutboxOptions>()
            .Bind(configuration.GetSection(OutboxOptions.SectionName))
            .ValidateOnStart();
        services.AddSingleton<IValidateOptions<OutboxOptions>, OutboxOptionsValidator>();
        services.AddOptions<WebhookOptions>()
            .Bind(configuration.GetSection(WebhookOptions.SectionName))
            .ValidateOnStart();
        services.AddSingleton<IValidateOptions<WebhookOptions>, WebhookOptionsValidator>();

        services.AddSingleton(TimeProvider.System);
        services.AddSingleton(sp => new RetryPolicy(sp.GetRequiredService<IOptions<OutboxOptions>>().Value));

        services.AddScoped<ErpSendStrategy>();
        services.AddScoped<OutboxOutcomeWriter>();
        services.AddScoped<OutboxProcessor>();
        services.AddScoped<InvoiceEventApplier>();
        services.AddScoped<WebhookEventProcessor>();

        services.AddScoped<CreateInvoiceHandler>();
        services.AddScoped<ResendInvoiceHandler>();
        services.AddScoped<InvoiceQueries>();

        return services;
    }
}
