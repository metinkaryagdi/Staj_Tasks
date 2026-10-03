using System.Text.RegularExpressions;

namespace ErpSimulator.Application.Invoices;

public sealed partial record CreateInvoiceRequest(
    string? InvoiceNumber,
    string? CustomerCode,
    decimal? Amount,
    string? Currency,
    DateOnly? InvoiceDate)
{
    public Dictionary<string, string[]> Validate()
    {
        var errors = new Dictionary<string, string[]>();

        if (string.IsNullOrWhiteSpace(InvoiceNumber) || InvoiceNumber.Length > 64)
            errors[nameof(InvoiceNumber)] = ["Required, max 64 characters."];

        if (string.IsNullOrWhiteSpace(CustomerCode) || CustomerCode.Length > 64)
            errors[nameof(CustomerCode)] = ["Required, max 64 characters."];

        // Same rule as the invoice service. amount is numeric(18,2): a third decimal would be rounded away silently.
        // The task: more than two digits after the decimal point gets 400. decimal keeps the digits as written
        // (1.230 has scale 3), so trailing zeros count too: 1.230 is rejected like 1.234.
        if (Amount is null or <= 0 || Amount.Value.Scale > 2)
            errors[nameof(Amount)] = ["Required, must be greater than 0 with at most 2 digits after the decimal point."];

        if (Currency is null || !CurrencyPattern().IsMatch(Currency))
            errors[nameof(Currency)] = ["Required, 3-letter ISO 4217 code (e.g. TRY, EUR)."];

        if (InvoiceDate is null)
            errors[nameof(InvoiceDate)] = ["Required, format yyyy-MM-dd."];

        return errors;
    }

    [GeneratedRegex("^[A-Z]{3}$")]
    private static partial Regex CurrencyPattern();
}
