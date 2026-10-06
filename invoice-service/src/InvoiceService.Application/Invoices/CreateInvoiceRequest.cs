using System.Text.RegularExpressions;

namespace InvoiceService.Application.Invoices;

/// <summary>The invoice number is not part of the request: the service generates it (FTR-000001).</summary>
public sealed partial record CreateInvoiceRequest(
    string? CustomerCode,
    decimal? Amount,
    string? Currency,
    DateOnly? InvoiceDate)
{
    /// <summary>
    /// Fits the amount column (numeric(18,2)) and is still shown to the cent by the operations screen, whose JSON numbers
    /// lose cents above about 90 trillion. A larger amount would fail at the database (500) or be shown wrong.
    /// </summary>
    public const decimal MaxAmount = 999_999_999_999.99m;

    public Dictionary<string, string[]> Validate()
    {
        var errors = new Dictionary<string, string[]>();

        if (string.IsNullOrWhiteSpace(CustomerCode) || CustomerCode.Length > 64)
            errors[nameof(CustomerCode)] = ["Required, max 64 characters."];

        // More than two decimals gets 400. Trailing zeros count: 1.230 has scale 3, like 1.234.
        if (Amount is null or <= 0 || Amount.Value.Scale > 2)
            errors[nameof(Amount)] = ["Required, must be greater than 0 with at most 2 digits after the decimal point."];
        else if (Amount > MaxAmount)
            errors[nameof(Amount)] = [$"Must be at most {MaxAmount.ToString(System.Globalization.CultureInfo.InvariantCulture)}."];

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
