using InvoiceService.Domain.Invoices;
using InvoiceService.Domain.Webhooks;

namespace InvoiceService.Application.Webhooks;

/// <summary>
/// Applies one ERP event to an invoice using <see cref="InvoiceTransitions"/>, plus the erp_reference check and the log
/// line. The caller's unit of work saves the changes.
/// </summary>
public sealed class InvoiceEventApplier(ILogger<InvoiceEventApplier> logger)
{
    public void Apply(Invoice invoice, ErpWebhookEvent ev, DateTimeOffset now, bool afterSend)
    {
        var before = invoice.Status;
        var transition = InvoiceTransitions.For(invoice.Status, ev.EventType);

        // Only an invoice the ERP has (Gönderildi or later) has a reference to compare with.
        if (transition.Outcome != TransitionOutcome.Wait && ev.ErpReference != invoice.ErpReference)
            transition = new Transition(TransitionOutcome.Ignore, IgnoreReason: IgnoreReason.ReferenceMismatch);

        switch (transition.Outcome)
        {
            case TransitionOutcome.Apply:
                invoice.Status = transition.NewStatus!;
                if (ev.EventType == WebhookEventType.Rejected)
                    invoice.RejectReason = ReadReason(ev.Payload);
                invoice.UpdatedAt = now;
                ev.Status = WebhookEventStatus.Processed;
                ev.ProcessedAt = now;
                break;
            case TransitionOutcome.Ignore:
                // Not applied to the invoice, so no processed_at; the decision's time is in the log.
                ev.Status = WebhookEventStatus.Ignored;
                ev.IgnoreReason = transition.IgnoreReason;
                break;
            case TransitionOutcome.Wait:
                ev.Status = WebhookEventStatus.Pending;
                break;
        }

        var message =
            "ERP webhook {Action} event={EventId} type={EventType} invoice={InvoiceNumber} status={Status} " +
            "invoiceStatus={Before}->{After} ignoreReason={IgnoreReason} eventErpReference={EventReference} " +
            "invoiceErpReference={InvoiceReference}";
        object?[] args =
        [
            afterSend ? "applied-after-send" : "stored", ev.EventId, ev.EventType, ev.InvoiceNumber, ev.Status,
            before, invoice.Status, ev.IgnoreReason ?? "-", ev.ErpReference, invoice.ErpReference ?? "-"
        ];
        // The task asks for a warning when the reference does not match.
        if (ev.IgnoreReason == IgnoreReason.ReferenceMismatch)
            logger.LogWarning(message, args);
        else
            logger.LogInformation(message, args);
    }

    /// <summary>The reason from the stored body (validated as present when the event arrived).</summary>
    private static string? ReadReason(string payload) =>
        System.Text.Json.JsonSerializer.Deserialize<ErpWebhookRequest>(payload, System.Text.Json.JsonSerializerOptions.Web)?.Reason;
}
