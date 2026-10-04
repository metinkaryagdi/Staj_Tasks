namespace InvoiceService.Application.Outbox;

/// <summary>
/// An outbox entry the worker has taken. <see cref="Attempt"/> is already counted. <see cref="AttemptsUsedUp"/>: the last
/// attempt was cut off before its outcome was written, so the ERP is only asked, not sent to again.
/// </summary>
public sealed record ClaimedEntry(long Id, string InvoiceNumber, int Attempt, bool AttemptsUsedUp, Guid ClaimToken)
{
    /// <summary>Short form of the claim token for the log.</summary>
    public string Claim => ClaimToken.ToString("N")[..8];
}
