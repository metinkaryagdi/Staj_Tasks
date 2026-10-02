namespace InvoiceService.Data;

/// <summary>
/// One event the ERP reported about an invoice (erp_webhook_events). Every event that passes the signature check is
/// stored exactly once, keyed by its event_id; a repeat only increments <see cref="DeliveryCount"/>.
/// </summary>
public sealed class ErpWebhookEvent
{
    /// <summary>The ERP's id of the event; primary key, so the same event can never be stored twice.</summary>
    public required string EventId { get; set; }

    /// <summary>One of <see cref="WebhookEventType"/>, enforced by a check constraint.</summary>
    public required string EventType { get; set; }

    public required string InvoiceNumber { get; set; }

    /// <summary>The ERP reference in the event; compared with the invoice's before the event is applied.</summary>
    public required string ErpReference { get; set; }

    /// <summary>When the event happened in the ERP (occurred_at in the body).</summary>
    public DateTimeOffset OccurredAt { get; set; }

    /// <summary>When the event first reached the service; repeats do not change it.</summary>
    public DateTimeOffset ReceivedAt { get; set; }

    /// <summary>When the event was applied to the invoice or ignored; null while Bekliyor.</summary>
    public DateTimeOffset? ProcessedAt { get; set; }

    /// <summary>One of <see cref="WebhookEventStatus"/>, enforced by a check constraint.</summary>
    public required string Status { get; set; }

    /// <summary>
    /// Added column: why the event was Yok Sayıldı (one of <see cref="Webhooks.IgnoreReason"/>); null otherwise.
    /// Checklist 3 counts "ignored because it would move the status back" separately from other ignored events.
    /// </summary>
    public string? IgnoreReason { get; set; }

    /// <summary>The request body exactly as received (text, not jsonb: jsonb would reorder and reformat it).</summary>
    public required string Payload { get; set; }

    /// <summary>
    /// Added column: how many times the event reached the service with a valid signature. A repeat is not applied
    /// again, only counted here; the number of repeats is delivery_count - 1.
    /// </summary>
    public int DeliveryCount { get; set; } = 1;
}

public static class WebhookEventType
{
    public const string Received = "invoice.received";
    public const string Approved = "invoice.approved";
    public const string Rejected = "invoice.rejected";

    public static readonly string[] All = [Received, Approved, Rejected];
}

public static class WebhookEventStatus
{
    /// <summary>Applied to the invoice.</summary>
    public const string Processed = "İşlendi";

    /// <summary>The invoice is not Gönderildi yet; applied when it becomes Gönderildi.</summary>
    public const string Pending = "Bekliyor";

    /// <summary>Not applied: it would move the invoice backwards, or its erp_reference does not match.</summary>
    public const string Ignored = "Yok Sayıldı";

    public static readonly string[] All = [Processed, Pending, Ignored];
}
