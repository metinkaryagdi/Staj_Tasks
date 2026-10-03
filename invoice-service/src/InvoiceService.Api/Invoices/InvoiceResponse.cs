using InvoiceService.Domain.Invoices;

namespace InvoiceService.Api.Invoices;

/// <summary>The invoice as the service stores it.</summary>
public sealed record InvoiceResponse(
    string InvoiceNumber,
    string CustomerCode,
    decimal Amount,
    string Currency,
    DateOnly InvoiceDate,
    string Status,
    string? ErpReference,
    string? RejectReason,
    string? LastError,
    int SendAttemptCount,
    DateTimeOffset CreatedAt,
    DateTimeOffset UpdatedAt)
{
    public static InvoiceResponse From(Invoice i) => new(
        i.InvoiceNumber, i.CustomerCode, i.Amount, i.Currency, i.InvoiceDate, i.Status,
        i.ErpReference, i.RejectReason, i.LastError, i.SendAttemptCount, i.CreatedAt, i.UpdatedAt);
}
