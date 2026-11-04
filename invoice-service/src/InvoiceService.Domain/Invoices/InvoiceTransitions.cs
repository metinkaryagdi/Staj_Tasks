using InvoiceService.Domain.Webhooks;

namespace InvoiceService.Domain.Invoices;

public enum TransitionOutcome
{
    /// <summary>The event moves the invoice forward to <see cref="Transition.NewStatus"/>.</summary>
    Apply,

    /// <summary>The event would not move the invoice forward; the invoice does not change (Yok Sayıldı).</summary>
    Ignore,

    /// <summary>The invoice is not Gönderildi yet; the event waits for it (Bekliyor).</summary>
    Wait
}

/// <param name="IgnoreReason">One of <see cref="IgnoreReason"/> when the outcome is
/// <see cref="TransitionOutcome.Ignore"/>.</param>
public readonly record struct Transition(TransitionOutcome Outcome, string? NewStatus = null, string? IgnoreReason = null);

/// <summary>
/// What an ERP event does to an invoice. Status only moves forward (Gönderildi -> İşleme Alındı -> Onaylandı /
/// Reddedildi, or straight to the decision). The ERP's cancellation moves any invoice it can be about to İptal Edildi; only
/// Reddedildi and İptal Edildi are final for it.
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
            WebhookEventType.Cancelled => InvoiceStatus.Cancelled,
            _ => throw new ArgumentOutOfRangeException(nameof(eventType), eventType, "Unknown event type.")
        };

        return invoiceStatus switch
        {
            // Başarısız and cancelled by the ERP: the ERP has it after all, and an invoice with a cancellation is not resent,
            // so nothing would ever release this event.
            InvoiceStatus.Failed when target == InvoiceStatus.Cancelled => new(TransitionOutcome.Apply, target),
            // Not at the ERP yet as far as the service knows (or a resend may still get it there).
            InvoiceStatus.Pending or InvoiceStatus.Failed => new(TransitionOutcome.Wait),
            InvoiceStatus.Sent => new(TransitionOutcome.Apply, target),
            InvoiceStatus.Processing when target != InvoiceStatus.Processing => new(TransitionOutcome.Apply, target),
            InvoiceStatus.Processing => new(TransitionOutcome.Ignore, IgnoreReason: IgnoreReason.NotForward),
            InvoiceStatus.Approved when target == InvoiceStatus.Cancelled => new(TransitionOutcome.Apply, target),
            InvoiceStatus.Approved or InvoiceStatus.Rejected or InvoiceStatus.Cancelled when target == InvoiceStatus.Processing =>
                new(TransitionOutcome.Ignore, IgnoreReason: IgnoreReason.Backward),
            InvoiceStatus.Approved or InvoiceStatus.Rejected or InvoiceStatus.Cancelled =>
                new(TransitionOutcome.Ignore, IgnoreReason: IgnoreReason.Final),
            _ => throw new ArgumentOutOfRangeException(nameof(invoiceStatus), invoiceStatus, "Unknown invoice status.")
        };
    }
}
