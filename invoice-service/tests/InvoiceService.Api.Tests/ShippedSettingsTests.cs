using InvoiceService.Application.Outbox;
using InvoiceService.Application.Webhooks;
using InvoiceService.Infrastructure.Erp;
using Microsoft.Extensions.Configuration;

namespace InvoiceService.Api.Tests;

/// <summary>The settings the service ships with (appsettings.json of the Api project, copied next to the test dll).</summary>
public class ShippedSettingsTests
{
    private static ErpOptions Bind(IConfiguration configuration)
    {
        var options = new ErpOptions();
        configuration.GetSection(ErpOptions.SectionName).Bind(options);
        return options;
    }

    private static OutboxOptions BindOutbox(IConfiguration configuration)
    {
        var options = new OutboxOptions();
        configuration.GetSection(OutboxOptions.SectionName).Bind(options);
        return options;
    }

    private static bool Validates(IConfiguration configuration)
    {
        var options = new WebhookOptions();
        configuration.GetSection(WebhookOptions.SectionName).Bind(options);
        return new WebhookOptionsValidator(configuration).Validate(null, options).Succeeded;
    }

    [Fact]
    public void Shipped_settings_use_a_10_second_timeout()
    {
        var path = Path.Combine(AppContext.BaseDirectory, "appsettings.json");
        var configuration = new ConfigurationBuilder().AddJsonFile(path).Build();
        Assert.Equal(10, Bind(configuration).TimeoutSeconds);
    }

    [Fact]
    public void Shipped_settings_follow_the_task_rules()
    {
        var path = Path.Combine(AppContext.BaseDirectory, "appsettings.json");
        var configuration = new ConfigurationBuilder().AddJsonFile(path).Build();
        var options = BindOutbox(configuration);

        Assert.True(new OutboxOptionsValidator(configuration).Validate(null, options).Succeeded);
        Assert.Equal(10, options.MaxConcurrentSends);
        Assert.Equal(10, options.MaxAttempts);
        Assert.Equal(60, options.MaxBackoffSeconds);
        Assert.Equal(0, options.BackoffMarginMilliseconds);
    }

    [Fact]
    public void Settings_file_response_limits_are_valid()
    {
        var path = Path.Combine(AppContext.BaseDirectory, "appsettings.json");
        var configuration = new ConfigurationBuilder().AddJsonFile(path).Build();
        Assert.True(Validates(configuration));
        Assert.True(configuration.GetValue<int>("ErpWebhooks:ResponseBudgetMilliseconds") < WebhookOptionsValidator.TaskResponseLimitMilliseconds);
    }
}
