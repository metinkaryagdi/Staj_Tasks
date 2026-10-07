using InvoiceService.Domain.Invoices;

namespace InvoiceService.Api.Invoices;

/// <summary>The invoice as the service stores it. <see cref="ErpCheckedAt"/> / <see cref="ErpCheckResult"/>: when the
/// reconciliation last asked the ERP about it and what the answer was (null if never).</summary>
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
    DateTimeOffset UpdatedAt,
    DateTimeOffset? ErpCheckedAt,
    string? ErpCheckResult)
{
    public static InvoiceResponse From(Invoice i) => new(
        i.InvoiceNumber, i.CustomerCode, i.Amount, i.Currency, i.InvoiceDate, i.Status,
        i.ErpReference, i.RejectReason, i.LastError, i.SendAttemptCount, i.CreatedAt, i.UpdatedAt,
        i.ErpCheckedAt, i.ErpCheckResult);
}
