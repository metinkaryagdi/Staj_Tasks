using InvoiceService.Domain.Invoices;

namespace InvoiceService.Domain.Tests;

public class InvoiceNumberTests
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
}
