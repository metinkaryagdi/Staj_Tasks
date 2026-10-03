using System.Globalization;
using InvoiceService.Application.Invoices;

namespace InvoiceService.Application.Tests;

public class CreateInvoiceRequestTests
{
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
    // Trailing zeros are digits after the decimal point too (decimal keeps them: 1.230m has scale 3).
    [InlineData("1.230")]
    [InlineData("1.2300")]
    public void Amount_with_more_than_two_decimals_is_rejected(string amount)
    {
        var errors = new CreateInvoiceRequest("C-001", decimal.Parse(amount, CultureInfo.InvariantCulture), "TRY", new DateOnly(2026, 9, 30)).Validate();
        Assert.Contains("Amount", errors.Keys);
    }

    [Theory]
    [InlineData("1.23")]
    [InlineData("1.20")]
    [InlineData("1.2")]
    [InlineData("5")]
    public void Amount_with_at_most_two_decimals_is_accepted(string amount)
    {
        var errors = new CreateInvoiceRequest("C-001", decimal.Parse(amount, CultureInfo.InvariantCulture), "TRY", new DateOnly(2026, 9, 30)).Validate();
        Assert.Empty(errors);
    }

    // The request body is JSON: the digits written there must reach the rule (System.Text.Json keeps 1.230 as scale 3).
    [Theory]
    [InlineData("1.230", true)]
    [InlineData("1.234", true)]
    [InlineData("1.23", false)]
    public void Amount_digits_survive_json(string amount, bool rejected)
    {
        var json = "{\"customerCode\":\"C-001\",\"amount\":" + amount + ",\"currency\":\"TRY\",\"invoiceDate\":\"2026-09-30\"}";
        var request = System.Text.Json.JsonSerializer.Deserialize<CreateInvoiceRequest>(json, System.Text.Json.JsonSerializerOptions.Web)!;
        Assert.Equal(rejected, request.Validate().ContainsKey("Amount"));
    }
}
