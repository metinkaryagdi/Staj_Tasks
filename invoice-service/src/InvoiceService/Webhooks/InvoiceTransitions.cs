using InvoiceService.Data;

namespace InvoiceService.Webhooks;

public enum TransitionOutcome
{
    /// <summary>The event moves the invoice forward to <see cref="Transition.NewStatus"/>.</summary>
    Apply,

    /// <summary>The event would not move the invoice forward; the invoice does not change (Yok Sayıldı).</summary>
    Ignore,

    /// <summary>The invoice is not Gönderildi yet; the event waits for it (Bekliyor).</summary>
    Wait
}

/// <param name="IgnoreReason">One of <see cref="IgnoreReason"/> when the outcome is <see cref="TransitionOutcome.Ignore"/>.</param>
public readonly record struct Transition(TransitionOutcome Outcome, string? NewStatus = null, string? IgnoreReason = null);

/// <summary>Why an event was Yok Sayıldı (erp_webhook_events.ignore_reason).</summary>
public static class IgnoreReason
{
    /// <summary>invoice.received after the decision (Onaylandı / Reddedildi): it would move the invoice back.</summary>
    public const string Backward = "Geri Götürüyor";

    /// <summary>A decision for an invoice that already has one: Onaylandı and Reddedildi are final.</summary>
    public const string Final = "Kesin Durumda";

    /// <summary>A second invoice.received while İşleme Alındı: not backwards, but not forward either.</summary>
    public const string NotForward = "İlerletmiyor";

    /// <summary>The event's erp_reference is not the invoice's: it is not about the record the service sent.</summary>
    public const string ReferenceMismatch = "Referans Farklı";

    public static readonly string[] All = [Backward, Final, NotForward, ReferenceMismatch];
}

/// <summary>
/// What an ERP event does to an invoice. Status only moves forward:
/// Gönderildi -> İşleme Alındı -> Onaylandı / Reddedildi, and Gönderildi -> Onaylandı / Reddedildi directly.
/// Onaylandı and Reddedildi are final.
/// </summary>
public static class InvoiceTransitions
{
    public static Transition For(string invoiceStatus, string eventType)
    {
        var target = eventType switch
        {
            WebhookEventType.Received => InvoiceStatus.Processing,
            WebhookEventType.Approved => InvoiceStatus.Approved,
            WebhookEventType.Rejected => InvoiceStatus.Rejected,
            _ => throw new ArgumentOutOfRangeException(nameof(eventType), eventType, "Unknown event type.")
        };

        return invoiceStatus switch
        {
            // Not at the ERP yet as far as the service knows (or a resend may still get it there).
            InvoiceStatus.Pending or InvoiceStatus.Failed => new(TransitionOutcome.Wait),
            InvoiceStatus.Sent => new(TransitionOutcome.Apply, target),
            InvoiceStatus.Processing when target != InvoiceStatus.Processing => new(TransitionOutcome.Apply, target),
            InvoiceStatus.Processing => new(TransitionOutcome.Ignore, IgnoreReason: IgnoreReason.NotForward),
            InvoiceStatus.Approved or InvoiceStatus.Rejected when target == InvoiceStatus.Processing =>
                new(TransitionOutcome.Ignore, IgnoreReason: IgnoreReason.Backward),
            InvoiceStatus.Approved or InvoiceStatus.Rejected => new(TransitionOutcome.Ignore, IgnoreReason: IgnoreReason.Final),
            _ => throw new ArgumentOutOfRangeException(nameof(invoiceStatus), invoiceStatus, "Unknown invoice status.")
        };
    }
}
