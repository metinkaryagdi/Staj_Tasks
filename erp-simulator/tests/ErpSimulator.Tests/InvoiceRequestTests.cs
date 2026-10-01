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
    public void Amount_with_more_than_two_decimals_is_rejected(string amount)
    {
        Assert.Contains("Amount", Validate(amount).Keys);
    }

    // decimal keeps trailing zeros (1.230m has scale 3), but they do not change the value.
    [Theory]
    [InlineData("1.23")]
    [InlineData("1.230")]
    [InlineData("1.2300")]
    [InlineData("5")]
    public void Amount_with_trailing_zeros_is_accepted(string amount)
    {
        Assert.Empty(Validate(amount));
    }
}
