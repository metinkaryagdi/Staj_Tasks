namespace InvoiceService.Application.Outbox;

/// <summary>
/// An outbox entry the worker has taken. <see cref="Attempt"/> is already counted. <see cref="AttemptsUsedUp"/>: the
/// last attempt was cut off before its outcome was written, so the ERP is only asked, not sent to again.
/// <see cref="DueAt"/>: the entry's next_attempt_at when it was taken. <see cref="TraceParent"/>: the invoice's trace the
/// attempt continues; null until the worker takes the entry for the first time and starts it. <see cref="CreatedAt"/>:
/// when the entry entered the queue, where the first attempt's queue wait starts.
/// </summary>
public sealed record ClaimedEntry(
    long Id, string InvoiceNumber, int Attempt, bool AttemptsUsedUp, Guid ClaimToken, DateTimeOffset DueAt = default,
    string? TraceParent = null, DateTimeOffset CreatedAt = default)
{
    /// <summary>Short form of the claim token for the log.</summary>
    public string Claim => ClaimToken.ToString("N")[..8];
}
