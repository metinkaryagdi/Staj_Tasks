using System.Globalization;
using InvoiceService.Data;
using InvoiceService.Erp;
using InvoiceService.Invoices;
using InvoiceService.Outbox;
using Microsoft.Extensions.Configuration;

namespace InvoiceService.Tests;

public class InvoiceRulesTests
{
    [Theory]
    [InlineData(1, "FTR-000001")]
    [InlineData(42, "FTR-000042")]
    [InlineData(999_999, "FTR-999999")]
    [InlineData(1_000_000, "FTR-1000000")]
    public void Invoice_number_format(long sequence, string expected)
    {
        Assert.Equal(expected, InvoiceNumber.Format(sequence));
    }

    [Fact]
    public void Valid_request_has_no_errors()
    {
        var request = new CreateInvoiceRequest("C-001", 1250.50m, "TRY", new DateOnly(2026, 9, 30));
        Assert.Empty(request.Validate());
    }

    [Fact]
    public void Invalid_request_reports_every_field()
    {
        var errors = new CreateInvoiceRequest("", -5, "lira", null).Validate();
        Assert.Equal(
            ["Amount", "Currency", "CustomerCode", "InvoiceDate"],
            errors.Keys.Order().ToArray());
    }

    [Theory]
    [InlineData("TRY\n")]   // .NET's $ also matches before a final newline
    [InlineData("TRY\r\n")]
    [InlineData(" TRY")]
    [InlineData("TRY ")]
    [InlineData("try")]
    [InlineData("TR")]
    [InlineData("TRYY")]
    public void Currency_must_be_exactly_three_capital_letters(string currency)
    {
        var errors = new CreateInvoiceRequest("C-001", 10m, currency, new DateOnly(2026, 9, 30)).Validate();
        Assert.Contains("Currency", errors.Keys);
    }

    [Theory]
    [InlineData("10.005")]
    [InlineData("1.234")]
    [InlineData("1.2301")]
    public void Amount_with_more_than_two_decimals_is_rejected(string amount)
    {
        var errors = new CreateInvoiceRequest("C-001", decimal.Parse(amount, CultureInfo.InvariantCulture), "TRY", new DateOnly(2026, 9, 30)).Validate();
        Assert.Contains("Amount", errors.Keys);
    }

    // decimal keeps trailing zeros (1.230m has scale 3), but they do not change the value.
    [Theory]
    [InlineData("1.23")]
    [InlineData("1.230")]
    [InlineData("1.2300")]
    [InlineData("5")]
    public void Amount_with_trailing_zeros_is_accepted(string amount)
    {
        var errors = new CreateInvoiceRequest("C-001", decimal.Parse(amount, CultureInfo.InvariantCulture), "TRY", new DateOnly(2026, 9, 30)).Validate();
        Assert.Empty(errors);
    }

    private static IConfiguration Settings(string? baseUrl = "http://erp-simulator:8080", string? timeout = "10") =>
        new ConfigurationBuilder().AddInMemoryCollection(new Dictionary<string, string?>
        {
            ["Erp:BaseUrl"] = baseUrl,
            ["Erp:TimeoutSeconds"] = timeout
        }).Build();

    private static ErpOptions Bind(IConfiguration configuration)
    {
        var options = new ErpOptions();
        configuration.GetSection(ErpOptions.SectionName).Bind(options);
        return options;
    }

    [Fact]
    public void Erp_settings_are_read_from_the_settings_file()
    {
        var configuration = Settings();
        var options = Bind(configuration);

        Assert.True(new ErpOptionsValidator(configuration).Validate(null, options).Succeeded);
        Assert.Equal(10, options.TimeoutSeconds);
    }

    [Theory]
    [InlineData(null, "10", "Erp:BaseUrl is missing")]
    [InlineData("http://erp-simulator:8080", null, "Erp:TimeoutSeconds is missing")]
    [InlineData("not a url", "10", "Erp:BaseUrl must be an absolute")]
    [InlineData("http://erp-simulator:8080", "0", "Erp:TimeoutSeconds must be greater than 0")]
    public void Invalid_erp_settings_are_rejected(string? baseUrl, string? timeout, string message)
    {
        var configuration = Settings(baseUrl, timeout);
        var result = new ErpOptionsValidator(configuration).Validate(null, Bind(configuration));

        Assert.True(result.Failed);
        Assert.Contains(message, result.FailureMessage);
    }

    [Fact]
    public void Shipped_settings_use_a_10_second_timeout()
    {
        var path = Path.Combine(AppContext.BaseDirectory, "appsettings.json");
        var configuration = new ConfigurationBuilder().AddJsonFile(path).Build();
        Assert.Equal(10, Bind(configuration).TimeoutSeconds);
    }

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
    public void A_very_large_backoff_cap_does_not_overflow_into_a_rejection()
    {
        // 3 000 000 s * 1000 does not fit in an int; it must not wrap around to a negative limit.
        var configuration = OutboxSettings(("Outbox:MaxBackoffSeconds", "3000000"));
        Assert.True(new OutboxOptionsValidator(configuration).Validate(null, BindOutbox(configuration)).Succeeded);
    }
}
