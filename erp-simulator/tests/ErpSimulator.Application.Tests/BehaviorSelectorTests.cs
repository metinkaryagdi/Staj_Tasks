using ErpSimulator.Application.Simulation;
using Microsoft.Extensions.Configuration;
using Microsoft.Extensions.Options;

namespace ErpSimulator.Application.Tests;

public class BehaviorSelectorTests
{
    // Same values as appsettings.json; SimulatorOptions itself has no defaults.
    private static BehaviorRates DefaultRates() =>
        new() { Success = 60, Busy = 15, ServerError = 10, SaveThenError = 5, LateResponse = 10 };

    private static SimulatorOptions DefaultOptions(int seed = 42, BehaviorRates? rates = null) => new()
    {
        Seed = seed,
        Rates = rates ?? DefaultRates(),
        LateResponseDelaySeconds = 30,
        RetryAfterMinSeconds = 5,
        RetryAfterMaxSeconds = 30,
        RetryAfterFormat = RetryAfterFormat.Seconds
    };

    private static BehaviorSelector Create(int seed = 42, BehaviorRates? rates = null) =>
        new(Options.Create(DefaultOptions(seed, rates)));

    private static IConfiguration SettingsFile(string? withoutKey = null, IDictionary<string, string?>? overrides = null)
    {
        var values = new Dictionary<string, string?>
        {
            ["Simulator:Seed"] = "42",
            ["Simulator:Rates:Success"] = "60",
            ["Simulator:Rates:Busy"] = "15",
            ["Simulator:Rates:ServerError"] = "10",
            ["Simulator:Rates:SaveThenError"] = "5",
            ["Simulator:Rates:LateResponse"] = "10",
            ["Simulator:LateResponseDelaySeconds"] = "30",
            ["Simulator:RetryAfterMinSeconds"] = "5",
            ["Simulator:RetryAfterMaxSeconds"] = "30",
            ["Simulator:RetryAfterFormat"] = "Seconds",
            ["Simulator:IdempotentInvoices"] = "false",
            ["Simulator:ProcessingMinMilliseconds"] = "50",
            ["Simulator:ProcessingMaxMilliseconds"] = "200"
        };
        if (withoutKey is not null)
            values.Remove($"Simulator:{withoutKey}");
        foreach (var (key, value) in overrides ?? new Dictionary<string, string?>())
            values[key] = value;
        return new ConfigurationBuilder().AddInMemoryCollection(values).Build();
    }

    private static SimulatorOptions Bind(IConfiguration configuration)
    {
        var options = new SimulatorOptions();
        configuration.GetSection(SimulatorOptions.SectionName).Bind(options);
        return options;
    }

    private static List<Behavior> Draw(BehaviorSelector selector, int count) =>
        Enumerable.Range(0, count).Select(_ => selector.Next().Behavior).ToList();

    [Fact]
    public void Same_seed_produces_same_sequence()
    {
        Assert.Equal(Draw(Create(seed: 7), 500), Draw(Create(seed: 7), 500));
    }

    [Fact]
    public void Different_seed_produces_different_sequence()
    {
        Assert.NotEqual(Draw(Create(seed: 1), 100), Draw(Create(seed: 2), 100));
    }

    [Fact]
    public void All_failure_rates_zero_means_always_success()
    {
        var selector = Create(rates: new BehaviorRates { Success = 100, Busy = 0, ServerError = 0, SaveThenError = 0, LateResponse = 0 });
        Assert.All(Draw(selector, 1000), b => Assert.Equal(Behavior.Success, b));
    }

    [Theory]
    [InlineData(Behavior.Busy)]
    [InlineData(Behavior.ServerError)]
    [InlineData(Behavior.SaveThenError)]
    [InlineData(Behavior.LateResponse)]
    public void Rate_of_100_always_picks_that_behavior(Behavior expected)
    {
        var rates = new BehaviorRates
        {
            Success = 0,
            Busy = expected == Behavior.Busy ? 100 : 0,
            ServerError = expected == Behavior.ServerError ? 100 : 0,
            SaveThenError = expected == Behavior.SaveThenError ? 100 : 0,
            LateResponse = expected == Behavior.LateResponse ? 100 : 0
        };
        Assert.All(Draw(Create(rates: rates), 1000), b => Assert.Equal(expected, b));
    }

    [Fact]
    public void Default_rates_roughly_match_configured_distribution()
    {
        const int n = 100_000;
        var counts = Draw(Create(), n).GroupBy(b => b).ToDictionary(g => g.Key, g => g.Count() * 100.0 / n);

        Assert.InRange(counts[Behavior.Success], 59, 61);
        Assert.InRange(counts[Behavior.Busy], 14, 16);
        Assert.InRange(counts[Behavior.ServerError], 9, 11);
        Assert.InRange(counts[Behavior.SaveThenError], 4, 6);
        Assert.InRange(counts[Behavior.LateResponse], 9, 11);
    }

    [Fact]
    public void Retry_after_is_within_configured_range()
    {
        var selector = Create();
        var values = Enumerable.Range(0, 10_000).Select(_ => selector.Next().RetryAfterSeconds).ToList();

        Assert.Equal(5, values.Min());
        Assert.Equal(30, values.Max());
    }

    [Fact]
    public void Validator_rejects_negative_rate()
    {
        // Total is 100, so only the negative value can make it fail.
        var options = DefaultOptions(rates: new BehaviorRates { Success = 76, Busy = -1, ServerError = 10, SaveThenError = 5, LateResponse = 10 });
        var result = new SimulatorOptionsValidator(SettingsFile()).Validate(null, options);

        Assert.True(result.Failed);
        Assert.Contains("Simulator:Rates:Busy must be a number between 0 and 100 (was -1)", result.FailureMessage);
    }

    [Fact]
    public void Validator_rejects_busy_100_when_other_rates_are_left_as_is()
    {
        // Busy = 100 on top of the defaults: 60 + 100 + 10 + 5 + 10 = 185, which would silently mean 54% busy.
        var configuration = SettingsFile(overrides: new Dictionary<string, string?> { ["Simulator:Rates:Busy"] = "100" });
        var result = new SimulatorOptionsValidator(configuration).Validate(null, Bind(configuration));

        Assert.True(result.Failed);
        Assert.Contains("Simulator:Rates must add up to exactly 100 (was 185", result.FailureMessage);
    }

    [Theory]
    [InlineData(60, 15, 10, 5, 9, "99")]
    [InlineData(60, 15, 10, 5, 11, "101")]
    [InlineData(60, 0, 0, 0, 0, "60")]
    public void Validator_rejects_rates_not_adding_up_to_100(
        double success, double busy, double serverError, double saveThenError, double lateResponse, string total)
    {
        var options = DefaultOptions(rates: new BehaviorRates
        {
            Success = success, Busy = busy, ServerError = serverError, SaveThenError = saveThenError, LateResponse = lateResponse
        });
        var result = new SimulatorOptionsValidator(SettingsFile()).Validate(null, options);

        Assert.True(result.Failed);
        Assert.Contains($"(was {total}:", result.FailureMessage);
    }

    [Theory]
    [InlineData("NaN", "(was NaN:")]
    [InlineData("Infinity", "(was Infinity:")]
    [InlineData("-Infinity", "(was -Infinity:")]
    public void Validator_rejects_rates_that_are_not_numbers(string success, string total)
    {
        // double.Parse accepts these strings, and every comparison with NaN is false, so they need an explicit check.
        var configuration = SettingsFile(overrides: new Dictionary<string, string?> { ["Simulator:Rates:Success"] = success });
        var result = new SimulatorOptionsValidator(configuration).Validate(null, Bind(configuration));

        Assert.True(result.Failed);
        Assert.Contains("Simulator:Rates:Success must be a number between 0 and 100", result.FailureMessage);
        Assert.Contains($"Simulator:Rates must add up to exactly 100 {total}", result.FailureMessage);
    }

    [Fact]
    public void Validator_accepts_fractional_rates_adding_up_to_100()
    {
        var options = DefaultOptions(rates: new BehaviorRates { Success = 33.3, Busy = 33.3, ServerError = 33.4 });
        Assert.True(new SimulatorOptionsValidator(SettingsFile()).Validate(null, options).Succeeded);
    }

    [Fact]
    public void Validator_rejects_all_rates_zero()
    {
        var options = DefaultOptions(rates: new BehaviorRates());
        Assert.True(new SimulatorOptionsValidator(SettingsFile()).Validate(null, options).Failed);
    }

    [Fact]
    public void Every_value_is_read_from_the_settings_file()
    {
        var configuration = SettingsFile();
        var options = Bind(configuration);

        Assert.True(new SimulatorOptionsValidator(configuration).Validate(null, options).Succeeded);
        Assert.Equal(42, options.Seed);
        Assert.Equal(60, options.Rates.Success);
        Assert.Equal(15, options.Rates.Busy);
        Assert.Equal(10, options.Rates.ServerError);
        Assert.Equal(5, options.Rates.SaveThenError);
        Assert.Equal(10, options.Rates.LateResponse);
        Assert.Equal(30, options.LateResponseDelaySeconds);
        Assert.Equal(5, options.RetryAfterMinSeconds);
        Assert.Equal(30, options.RetryAfterMaxSeconds);
        Assert.Equal(RetryAfterFormat.Seconds, options.RetryAfterFormat);
        Assert.False(options.IdempotentInvoices);
        Assert.Equal(50, options.ProcessingMinMilliseconds);
        Assert.Equal(200, options.ProcessingMaxMilliseconds);
    }

    [Theory]
    [InlineData("-1", "200")]
    [InlineData("201", "200")]
    public void Validator_rejects_a_processing_range_that_is_negative_or_reversed(string min, string max)
    {
        var configuration = SettingsFile(overrides: new Dictionary<string, string?>
        {
            ["Simulator:ProcessingMinMilliseconds"] = min, ["Simulator:ProcessingMaxMilliseconds"] = max
        });

        var result = new SimulatorOptionsValidator(configuration).Validate(null, Bind(configuration));

        Assert.True(result.Failed);
        Assert.Contains("ProcessingMinMilliseconds/ProcessingMaxMilliseconds", result.FailureMessage);
    }

    [Fact]
    public void Validator_accepts_a_fixed_processing_time()
    {
        var configuration = SettingsFile(overrides: new Dictionary<string, string?>
        {
            ["Simulator:ProcessingMinMilliseconds"] = "0", ["Simulator:ProcessingMaxMilliseconds"] = "0"
        });

        Assert.True(new SimulatorOptionsValidator(configuration).Validate(null, Bind(configuration)).Succeeded);
    }

    [Fact]
    public void Idempotent_invoices_can_be_switched_on_from_the_settings_file()
    {
        var configuration = SettingsFile(overrides: new Dictionary<string, string?> { ["Simulator:IdempotentInvoices"] = "true" });
        var options = Bind(configuration);

        Assert.True(new SimulatorOptionsValidator(configuration).Validate(null, options).Succeeded);
        Assert.True(options.IdempotentInvoices);
    }

    public static TheoryData<string> RequiredKeys => new(SimulatorOptionsValidator.RequiredKeys);

    [Theory]
    [MemberData(nameof(RequiredKeys))]
    public void Missing_setting_is_rejected(string key)
    {
        var configuration = SettingsFile(withoutKey: key);
        var result = new SimulatorOptionsValidator(configuration).Validate(null, Bind(configuration));

        Assert.True(result.Failed);
        Assert.Contains($"Simulator:{key} is missing", result.FailureMessage);
    }
}
