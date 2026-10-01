using System.Text.RegularExpressions;

namespace ErpSimulator.Invoices;

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
        // Trailing zeros are not extra decimals: 1.230 is the same value as 1.23 and is accepted.
        if (Amount is null or <= 0 || decimal.Round(Amount.Value, 2) != Amount.Value)
            errors[nameof(Amount)] = ["Required, must be greater than 0 with at most 2 decimals."];

        if (Currency is null || !CurrencyPattern().IsMatch(Currency))
            errors[nameof(Currency)] = ["Required, 3-letter ISO 4217 code (e.g. TRY, EUR)."];

        if (InvoiceDate is null)
            errors[nameof(InvoiceDate)] = ["Required, format yyyy-MM-dd."];

        return errors;
    }

    [GeneratedRegex("^[A-Z]{3}$")]
    private static partial Regex CurrencyPattern();
}

public sealed record InvoiceAcceptedResponse(string ErpReference, string InvoiceNumber, DateTimeOffset ReceivedAt);

public sealed record InvoiceRecordResponse(
    string ErpReference,
    string CustomerCode,
    decimal Amount,
    string Currency,
    DateOnly InvoiceDate,
    DateTimeOffset ReceivedAt);

/// <summary>
/// Because the simulator allows duplicates, one invoice number can map to several ERP records.
/// <see cref="ErpReference"/> is the first (oldest) one; <see cref="Records"/> lists all of them.
/// </summary>
public sealed record InvoiceLookupResponse(
    string InvoiceNumber,
    bool Registered,
    string ErpReference,
    int RecordCount,
    IReadOnlyList<InvoiceRecordResponse> Records);
