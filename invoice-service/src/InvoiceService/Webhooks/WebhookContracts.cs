using System.Text.Json.Serialization;
using InvoiceService.Data;

namespace InvoiceService.Webhooks;

/// <summary>The body of an ERP event, as the ERP simulator sends it (snake_case).</summary>
public sealed record ErpWebhookRequest(
    [property: JsonPropertyName("event_id")] string? EventId,
    [property: JsonPropertyName("event_type")] string? EventType,
    [property: JsonPropertyName("invoice_number")] string? InvoiceNumber,
    [property: JsonPropertyName("erp_reference")] string? ErpReference,
    [property: JsonPropertyName("occurred_at")] DateTimeOffset? OccurredAt,
    [property: JsonPropertyName("reason")] string? Reason)
{
    /// <summary>Checked only after the signature: an unsigned body never gets this far.</summary>
    public Dictionary<string, string[]> Validate()
    {
        var errors = new Dictionary<string, string[]>();

        // Same lengths as the erp_webhook_events columns.
        if (string.IsNullOrWhiteSpace(EventId) || EventId.Length > 64)
            errors["event_id"] = ["Required, max 64 characters."];

        if (EventType is null || !WebhookEventType.All.Contains(EventType))
            errors["event_type"] = [$"Required, one of: {string.Join(", ", WebhookEventType.All)}."];

        if (string.IsNullOrWhiteSpace(InvoiceNumber) || InvoiceNumber.Length > 32)
            errors["invoice_number"] = ["Required, max 32 characters."];

        if (string.IsNullOrWhiteSpace(ErpReference) || ErpReference.Length > 32)
            errors["erp_reference"] = ["Required, max 32 characters."];

        if (OccurredAt is null)
            errors["occurred_at"] = ["Required, ISO 8601 date and time."];

        if (EventType == WebhookEventType.Rejected && string.IsNullOrWhiteSpace(Reason))
            errors["reason"] = ["Required for invoice.rejected."];

        return errors;
    }
}
