using System.Text.RegularExpressions;
using InvoiceService.Data;

namespace InvoiceService.Invoices;

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

        if (Amount is null or <= 0 || decimal.Round(Amount.Value, 2) != Amount.Value)
            errors[nameof(Amount)] = ["Required, must be greater than 0 with at most 2 decimals."];

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

/// <summary>The invoice as the service stores it.</summary>
public sealed record InvoiceResponse(
    string InvoiceNumber,
    string CustomerCode,
    decimal Amount,
    string Currency,
    DateOnly InvoiceDate,
    string Status,
    string? ErpReference,
    string? LastError,
    int SendAttemptCount,
    DateTimeOffset CreatedAt,
    DateTimeOffset UpdatedAt)
{
    public static InvoiceResponse From(Invoice i) => new(
        i.InvoiceNumber, i.CustomerCode, i.Amount, i.Currency, i.InvoiceDate, i.Status,
        i.ErpReference, i.LastError, i.SendAttemptCount, i.CreatedAt, i.UpdatedAt);
}
