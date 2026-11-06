using System.Text.Json;
using System.Text.Json.Serialization;
using InvoiceService.Domain.Webhooks;

namespace InvoiceService.Application.Webhooks;

/// <summary>The body of an ERP event in the old format (snake_case), which is also how the service works with it.</summary>
public sealed record ErpWebhookRequest(
    [property: JsonPropertyName("event_id")] string? EventId,
    [property: JsonPropertyName("event_type")] string? EventType,
    [property: JsonPropertyName("invoice_number")] string? InvoiceNumber,
    [property: JsonPropertyName("erp_reference")] string? ErpReference,
    [property: JsonPropertyName("occurred_at")] DateTimeOffset? OccurredAt,
    [property: JsonPropertyName("reason")] string? Reason)
{
    /// <summary>The name of the new format, in its "schema" field.</summary>
    public const string SchemaV2 = "erp.invoice-event.v2";

    /// <summary>
    /// Reads an event in either format: both keep coming during a move between versions and after one, whatever the setting
    /// says. Null for a schema the service does not know. Throws <see cref="JsonException"/> if it is not valid JSON.
    /// </summary>
    public static ErpWebhookRequest? Parse(byte[] body)
    {
        using var json = JsonDocument.Parse(body);
        if (json.RootElement.ValueKind != JsonValueKind.Object || !json.RootElement.TryGetProperty("schema", out var schema))
            return json.Deserialize<ErpWebhookRequest>(JsonSerializerOptions.Web);

        if (schema.ValueKind != JsonValueKind.String || schema.GetString() != SchemaV2)
            return null;

        var v2 = json.Deserialize<EventV2>(JsonSerializerOptions.Web)!;
        return new ErpWebhookRequest(v2.Id, v2.Type, v2.Invoice?.Number, v2.Invoice?.ErpReference, v2.OccurredAt, v2.Reason);
    }

    private sealed record EventV2(string? Id, string? Type, DateTimeOffset? OccurredAt, EventInvoiceV2? Invoice, string? Reason);

    private sealed record EventInvoiceV2(string? Number, string? ErpReference);

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
