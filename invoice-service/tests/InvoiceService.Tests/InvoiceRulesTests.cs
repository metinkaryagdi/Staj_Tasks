using InvoiceService.Data;
using InvoiceService.Erp;
using InvoiceService.Invoices;
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

    [Fact]
    public void Amount_with_more_than_two_decimals_is_rejected()
    {
        var errors = new CreateInvoiceRequest("C-001", 10.005m, "TRY", new DateOnly(2026, 9, 30)).Validate();
        Assert.Contains("Amount", errors.Keys);
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
}
