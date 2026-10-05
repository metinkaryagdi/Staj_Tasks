namespace InvoiceService.Domain.Outbox;

/// <summary>
/// One pending ERP send of an invoice (erp_outbox). Written in the same transaction as the invoice, then picked up
/// and sent by the background worker. One row per invoice: a resend resets this row instead of adding a new one.
/// </summary>
public sealed class ErpOutboxEntry
{
    public long Id { get; set; }

    /// <summary>The invoice to send; unique, so an invoice can never be queued twice.</summary>
    public required string InvoiceNumber { get; set; }

    /// <summary>One of <see cref="OutboxStatus"/>, enforced by a check constraint.</summary>
    public required string Status { get; set; }

    /// <summary>
    /// How many attempts this entry has used, at most Outbox:MaxAttempts (10 in appsettings.json); a resend sets it
    /// back to 0. Counted when the attempt starts, so an attempt cut off by a crash is counted too.
    /// </summary>
    public int AttemptCount { get; set; }

    /// <summary>
    /// The earliest time of the next attempt (Retry-After or backoff); the worker skips the entry until then.
    /// </summary>
    public DateTimeOffset NextAttemptAt { get; set; }

    /// <summary>Error of the last attempt; null if there was none or it succeeded.</summary>
    public string? LastError { get; set; }

    public DateTimeOffset CreatedAt { get; set; }

    /// <summary>When the entry became Tamamlandı or Başarısız; null while Bekliyor.</summary>
    public DateTimeOffset? ProcessedAt { get; set; }

    /// <summary>
    /// Added column: a worker that takes the entry owns it until this time. If the service is killed mid-send,
    /// the entry is not stuck: once the time passes, another worker can take it again.
    /// </summary>
    public DateTimeOffset? LockedUntil { get; set; }

    /// <summary>Added column: which service instance took the entry, so two running copies can be told apart.</summary>
    public string? LockedBy { get; set; }

    /// <summary>
    /// Added column: a new id every time a worker takes the entry. A worker whose lock ran out no longer matches it,
    /// so it can neither send nor overwrite the outcome of the worker that took the entry after it.
    /// </summary>
    public Guid? ClaimToken { get; set; }
}

public static class OutboxStatus
{
    public const string Pending = "Bekliyor";
    public const string Completed = "Tamamlandı";
    public const string Failed = "Başarısız";
}
