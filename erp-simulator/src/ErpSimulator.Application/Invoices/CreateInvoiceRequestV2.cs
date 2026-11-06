namespace ErpSimulator.Application.Invoices;

/// <summary>An invoice in API v2: the amount is a whole number of kuruş.</summary>
public sealed record CreateInvoiceRequestV2(
    string? InvoiceNumber,
    string? CustomerCode,
    long? AmountKurus,
    string? Currency,
    DateOnly? InvoiceDate)
{
    /// <summary>The same invoice as the handler takes it; a missing or non-positive amount fails its validation.</summary>
    public CreateInvoiceRequest ToRequest() =>
        new(InvoiceNumber, CustomerCode, AmountKurus / 100m, Currency, InvoiceDate);
}
