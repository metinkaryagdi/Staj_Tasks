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
            ["Reconciliation:UnknownEventAfterMinutes"] = "60",
            ["Reconciliation:NoDecisionAfterMinutes"] = "30"
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
    [InlineData("Reconciliation:NoDecisionAfterMinutes")]
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
    public void A_value_above_the_chosen_limit_is_refused_and_named(string key, string value)
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
    [InlineData("Reconciliation:NoDecisionAfterMinutes", "0")]
    public void A_value_that_is_not_greater_than_0_is_refused_and_named(string key, string value)
    {
        var result = Validate(Settings((key, value)));

        Assert.False(result.Succeeded);
        Assert.Contains($"{key} must be greater than 0", result.FailureMessage);
    }

    [Fact]
    public void No_decision_threshold_below_the_stuck_threshold_is_refused_and_equal_is_accepted()
    {
        var below = Validate(Settings(("Reconciliation:NoDecisionAfterMinutes", "1")));
        Assert.False(below.Succeeded);
        Assert.Contains("NoDecisionAfterMinutes must be at least StuckAfterMinutes", below.FailureMessage);

        Assert.True(Validate(Settings(("Reconciliation:NoDecisionAfterMinutes", "2"))).Succeeded);
    }
}
