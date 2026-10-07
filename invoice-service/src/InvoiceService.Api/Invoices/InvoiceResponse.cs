using InvoiceService.Domain.Invoices;

namespace InvoiceService.Api.Invoices;

/// <summary>The invoice as the service stores it. <see cref="ErpCheckedAt"/> / <see cref="ErpCheckResult"/>: when the
/// reconciliation last asked the ERP about it and what the answer was (null if never). <see cref="Stuck"/>: the summary
/// counts it as stuck (the same rule as the list's stuck=true).</summary>
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
    string? ErpCheckResult,
    bool Stuck)
{
    /// <param name="stuck">Whether the summary counts it as stuck; an invoice just created or queued again is not.</param>
    public static InvoiceResponse From(Invoice i, bool stuck = false) => new(
        i.InvoiceNumber, i.CustomerCode, i.Amount, i.Currency, i.InvoiceDate, i.Status,
        i.ErpReference, i.RejectReason, i.LastError, i.SendAttemptCount, i.CreatedAt, i.UpdatedAt,
        i.ErpCheckedAt, i.ErpCheckResult, stuck);
}
