using InvoiceService.Application.Invoices;
using InvoiceService.Application.Outbox;
using InvoiceService.Application.Reconciliation;
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
        services.AddOptions<ReconciliationOptions>()
            .Bind(configuration.GetSection(ReconciliationOptions.SectionName))
            .ValidateOnStart();
        services.AddSingleton<IValidateOptions<ReconciliationOptions>, ReconciliationOptionsValidator>();

        services.AddSingleton(TimeProvider.System);
        services.AddSingleton(sp => new RetryPolicy(sp.GetRequiredService<IOptions<OutboxOptions>>().Value));

        services.AddScoped<ErpSendStrategy>();
        services.AddScoped<OutboxOutcomeWriter>();
        services.AddScoped<OutboxProcessor>();
        services.AddScoped<InvoiceEventApplier>();
        services.AddScoped<WebhookEventProcessor>();

        services.AddSingleton<ReconciliationPlanner>();
        services.AddScoped<FixApplier>();
        services.AddScoped<ReconciliationRunner>();
        services.AddSingleton<ReconciliationService>();
        services.AddScoped<ReconciliationQueries>();

        services.AddScoped<CreateInvoiceHandler>();
        services.AddScoped<ResendInvoiceHandler>();
        services.AddScoped<ResendInvoicesHandler>();
        services.AddScoped<InvoiceFollowUpHandler>();
        services.AddScoped<InvoiceQueries>();

        return services;
    }
}
