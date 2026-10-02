using System.Globalization;
using ErpSimulator.Invoices;

namespace ErpSimulator.Tests;

public class InvoiceRequestTests
{
    private static Dictionary<string, string[]> Validate(string amount) =>
        new CreateInvoiceRequest("FTR-000001", "C-001", decimal.Parse(amount, CultureInfo.InvariantCulture), "TRY",
            new DateOnly(2026, 9, 30)).Validate();

    [Theory]
    [InlineData("10.005")]
    [InlineData("1.234")]
    [InlineData("1.2301")]
    // Trailing zeros are digits after the decimal point too (decimal keeps them: 1.230m has scale 3).
    [InlineData("1.230")]
    [InlineData("1.2300")]
    public void Amount_with_more_than_two_decimals_is_rejected(string amount)
    {
        Assert.Contains("Amount", Validate(amount).Keys);
    }

    [Theory]
    [InlineData("1.23")]
    [InlineData("1.20")]
    [InlineData("1.2")]
    [InlineData("5")]
    public void Amount_with_at_most_two_decimals_is_accepted(string amount)
    {
        Assert.Empty(Validate(amount));
    }
}
