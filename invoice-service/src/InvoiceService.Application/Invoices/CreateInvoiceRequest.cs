using System.Text.RegularExpressions;

namespace InvoiceService.Application.Invoices;

/// <summary>The invoice number is not part of the request: the service generates it (FTR-000001).</summary>
public sealed partial record CreateInvoiceRequest(
    string? CustomerCode,
    decimal? Amount,
    string? Currency,
    DateOnly? InvoiceDate)
{
    public Dictionary<string, string[]> Validate()
    {
        var errors = new Dictionary<string, string[]>();

        if (string.IsNullOrWhiteSpace(CustomerCode) || CustomerCode.Length > 64)
            errors[nameof(CustomerCode)] = ["Required, max 64 characters."];

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

    // \z, not $: in .NET $ also matches before a trailing newline, which let "TRY\n" through.
    [GeneratedRegex(@"^[A-Z]{3}\z")]
    private static partial Regex CurrencyPattern();
}
