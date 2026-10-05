using InvoiceService.Application.Reconciliation;
using Microsoft.Extensions.Configuration;

namespace InvoiceService.Application.Tests;

public class ReconciliationOptionsTests
{
    private static IConfiguration Settings(params (string Key, string? Value)[] overrides)
    {
        var values = new Dictionary<string, string?>
        {
            ["Reconciliation:IntervalMinutes"] = "60",
            ["Reconciliation:LookbackHours"] = "24",
            ["Reconciliation:StuckAfterMinutes"] = "2",
            ["Reconciliation:UnknownEventAfterMinutes"] = "60"
        };
        foreach (var (key, value) in overrides)
            values[key] = value;
        return new ConfigurationBuilder().AddInMemoryCollection(values).Build();
    }

    private static Microsoft.Extensions.Options.ValidateOptionsResult Validate(IConfiguration configuration)
    {
        var options = new ReconciliationOptions();
        configuration.GetSection(ReconciliationOptions.SectionName).Bind(options);
        return new ReconciliationOptionsValidator(configuration).Validate(null, options);
    }

    [Fact]
    public void Valid_settings_are_accepted()
    {
        Assert.True(Validate(Settings()).Succeeded);
    }

    [Theory]
    [InlineData("Reconciliation:IntervalMinutes")]
    [InlineData("Reconciliation:LookbackHours")]
    [InlineData("Reconciliation:StuckAfterMinutes")]
    [InlineData("Reconciliation:UnknownEventAfterMinutes")]
    public void A_missing_value_is_refused_and_named(string key)
    {
        var result = Validate(Settings((key, null)));

        Assert.False(result.Succeeded);
        Assert.Contains($"{key} is missing", result.FailureMessage);
    }

    [Theory]
    [InlineData("Reconciliation:IntervalMinutes", "10081")]
    [InlineData("Reconciliation:IntervalMinutes", "2147483647")]
    [InlineData("Reconciliation:LookbackHours", "8761")]
    [InlineData("Reconciliation:LookbackHours", "2147483647")]
    public void A_value_above_what_the_timer_and_the_dates_can_take_is_refused_and_named(string key, string value)
    {
        var result = Validate(Settings((key, value)));

        Assert.False(result.Succeeded);
        Assert.Contains($"{key} must be at most", result.FailureMessage);
    }

    [Theory]
    [InlineData("Reconciliation:IntervalMinutes", "10080")]
    [InlineData("Reconciliation:LookbackHours", "8760")]
    public void The_largest_accepted_values_are_accepted(string key, string value)
    {
        Assert.True(Validate(Settings((key, value))).Succeeded);
    }

    [Theory]
    [InlineData("Reconciliation:IntervalMinutes", "0")]
    [InlineData("Reconciliation:LookbackHours", "-1")]
    [InlineData("Reconciliation:StuckAfterMinutes", "0")]
    [InlineData("Reconciliation:UnknownEventAfterMinutes", "-5")]
    public void A_value_that_is_not_greater_than_0_is_refused_and_named(string key, string value)
    {
        var result = Validate(Settings((key, value)));

        Assert.False(result.Succeeded);
        Assert.Contains($"{key} must be greater than 0", result.FailureMessage);
    }
}
