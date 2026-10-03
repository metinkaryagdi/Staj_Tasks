using InvoiceService.Application.Outbox;
using Microsoft.Extensions.Configuration;

namespace InvoiceService.Application.Tests;

public class OutboxOptionsTests
{
    private static OutboxOptions BindOutbox(IConfiguration configuration)
    {
        var options = new OutboxOptions();
        configuration.GetSection(OutboxOptions.SectionName).Bind(options);
        return options;
    }

    private static IConfiguration OutboxSettings(params (string Key, string? Value)[] overrides)
    {
        var values = new Dictionary<string, string?>
        {
            ["Erp:TimeoutSeconds"] = "10",
            ["Outbox:MaxConcurrentSends"] = "10",
            ["Outbox:MaxAttempts"] = "10",
            ["Outbox:MaxBackoffSeconds"] = "60",
            ["Outbox:MaxJitterMilliseconds"] = "1000",
            ["Outbox:BackoffMarginMilliseconds"] = "0",
            ["Outbox:LockSeconds"] = "60",
            ["Outbox:IdleDelayMilliseconds"] = "250"
        };
        foreach (var (key, value) in overrides)
            values[key] = value;
        return new ConfigurationBuilder().AddInMemoryCollection(values).Build();
    }

    [Fact]
    public void Valid_outbox_settings_are_accepted()
    {
        var configuration = OutboxSettings();
        Assert.True(new OutboxOptionsValidator(configuration).Validate(null, BindOutbox(configuration)).Succeeded);
    }

    [Theory]
    [InlineData("Outbox:MaxConcurrentSends", null, "Outbox:MaxConcurrentSends is missing")]
    [InlineData("Outbox:MaxAttempts", null, "Outbox:MaxAttempts is missing")]
    [InlineData("Outbox:MaxBackoffSeconds", null, "Outbox:MaxBackoffSeconds is missing")]
    [InlineData("Outbox:MaxJitterMilliseconds", null, "Outbox:MaxJitterMilliseconds is missing")]
    [InlineData("Outbox:BackoffMarginMilliseconds", null, "Outbox:BackoffMarginMilliseconds is missing")]
    [InlineData("Outbox:LockSeconds", null, "Outbox:LockSeconds is missing")]
    [InlineData("Outbox:IdleDelayMilliseconds", null, "Outbox:IdleDelayMilliseconds is missing")]
    [InlineData("Outbox:MaxConcurrentSends", "0", "Outbox:MaxConcurrentSends must be greater than 0")]
    [InlineData("Outbox:MaxAttempts", "0", "Outbox:MaxAttempts must be greater than 0")]
    [InlineData("Outbox:MaxBackoffSeconds", "0", "Outbox:MaxBackoffSeconds must be greater than 0")]
    [InlineData("Outbox:MaxJitterMilliseconds", "60000", "Outbox:MaxJitterMilliseconds must be at least 0 and less than")]
    [InlineData("Outbox:MaxJitterMilliseconds", "-1", "Outbox:MaxJitterMilliseconds must be at least 0 and less than")]
    [InlineData("Outbox:IdleDelayMilliseconds", "0", "Outbox:IdleDelayMilliseconds must be greater than 0")]
    [InlineData("Outbox:BackoffMarginMilliseconds", "-1", "Outbox:BackoffMarginMilliseconds must be at least 0")]
    [InlineData("Outbox:BackoffMarginMilliseconds", "59000", "Outbox:BackoffMarginMilliseconds must be at least 0")]
    [InlineData("Outbox:BackoffMarginMilliseconds", "2147483647", "Outbox:BackoffMarginMilliseconds must be at least 0")]
    [InlineData("Outbox:LockSeconds", "30", "Outbox:LockSeconds must be longer than 3 x Erp:TimeoutSeconds")]
    public void Invalid_outbox_settings_are_rejected(string key, string? value, string message)
    {
        var configuration = OutboxSettings((key, value));
        var result = new OutboxOptionsValidator(configuration).Validate(null, BindOutbox(configuration));

        Assert.True(result.Failed);
        Assert.Contains(message, result.FailureMessage);
    }

    [Fact]
    public void A_very_large_backoff_cap_does_not_overflow_into_a_rejection()
    {
        // 3 000 000 s * 1000 does not fit in an int; it must not wrap around to a negative limit.
        var configuration = OutboxSettings(("Outbox:MaxBackoffSeconds", "3000000"));
        Assert.True(new OutboxOptionsValidator(configuration).Validate(null, BindOutbox(configuration)).Succeeded);
    }
}
