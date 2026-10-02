namespace ErpSimulator.Data;

/// <summary>
/// One event the simulator sends to the invoice service (webhook_deliveries). Written in the same transaction as the
/// invoice record, then sent by <see cref="Webhooks.WebhookDispatcher"/> when <see cref="DueAt"/> comes, and sent again
/// after a failure until it is delivered or its retries are used up. Kept in the database, so a simulator restart
/// does not lose events that are still to be sent.
/// </summary>
public sealed class WebhookDelivery
{
    public long Id { get; set; }

    /// <summary>The event's id (event_id in the body). A duplicate delivery repeats the same id.</summary>
    public required string EventId { get; set; }

    public required string EventType { get; set; }

    /// <summary>The ERP record the event is about.</summary>
    public long InvoiceId { get; set; }

    public required string InvoiceNumber { get; set; }

    /// <summary>One of <see cref="DeliveryKind"/>: a normal event or one of the deliberate problems.</summary>
    public required string Kind { get; set; }

    /// <summary>
    /// The JSON body, built once when the row is written: every send of this row (and a duplicate of it) carries
    /// exactly the same bytes. Only the timestamp and the signature are made at send time.
    /// </summary>
    public required string Payload { get; set; }

    /// <summary>When the event happened in the ERP (occurred_at in the body).</summary>
    public DateTimeOffset OccurredAt { get; set; }

    /// <summary>When the next send is due.</summary>
    public DateTimeOffset DueAt { get; set; }

    /// <summary>One of <see cref="DeliveryStatus"/>.</summary>
    public required string Status { get; set; }

    /// <summary>When the first send started (before the HTTP request); null until the row is first sent.</summary>
    public DateTimeOffset? FirstSentAt { get; set; }

    /// <summary>Sends made so far (the first one included).</summary>
    public int AttemptCount { get; set; }

    /// <summary>HTTP status of the last send; null if it got no answer (timeout, connection refused).</summary>
    public int? LastHttpStatus { get; set; }

    public string? LastError { get; set; }

    public DateTimeOffset CreatedAt { get; set; }

    /// <summary>When the invoice service answered 2xx (or rejected a fake/replayed event); null until then.</summary>
    public DateTimeOffset? CompletedAt { get; set; }
}

public static class DeliveryStatus
{
    public const string Pending = "Pending";

    /// <summary>The invoice service answered 2xx.</summary>
    public const string Delivered = "Delivered";

    /// <summary>No 2xx after the first send and every retry.</summary>
    public const string Failed = "Failed";

    /// <summary>A fake or replayed event the invoice service rejected: not sent again (task rule).</summary>
    public const string Rejected = "Rejected";

    /// <summary>Never sent on purpose (a lost decision): kept so the simulator can tell which invoices lost theirs.</summary>
    public const string Skipped = "Skipped";

    public static readonly string[] All = [Pending, Delivered, Failed, Rejected, Skipped];
}

/// <summary>A normal event or one of the deliberate problems (Webhooks:Problems).</summary>
public static class DeliveryKind
{
    public const string Normal = "Normal";

    /// <summary>A second send of a normal event, same event_id and body.</summary>
    public const string Duplicate = "Duplicate";

    /// <summary>The decision that is never sent (status Skipped).</summary>
    public const string LostDecision = "LostDecision";

    /// <summary>A decision with its own event_id, signed with a wrong key.</summary>
    public const string Fake = "Fake";

    /// <summary>An already planned event sent again later with a timestamp Webhooks:Problems:ReplayAgeSeconds old,
    /// validly signed for that timestamp.</summary>
    public const string Replay = "Replay";

    public static readonly string[] All = [Normal, Duplicate, LostDecision, Fake, Replay];

    /// <summary>Kinds the invoice service is expected to reject; once rejected they are not sent again.</summary>
    public static bool NotRetriedWhenRejected(string kind) => kind is Fake or Replay;
}

public static class ErpEventType
{
    public const string Received = "invoice.received";
    public const string Approved = "invoice.approved";
    public const string Rejected = "invoice.rejected";
}
