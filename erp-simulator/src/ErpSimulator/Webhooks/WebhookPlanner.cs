using System.Text.Json;
using System.Text.Json.Serialization;
using ErpSimulator.Data;
using ErpSimulator.Simulation;
using Microsoft.Extensions.Options;

namespace ErpSimulator.Webhooks;

/// <summary>The event body as the invoice service expects it (snake_case; reason only on invoice.rejected).</summary>
public sealed record ErpEventBody(
    [property: JsonPropertyName("event_id")] string EventId,
    [property: JsonPropertyName("event_type")] string EventType,
    [property: JsonPropertyName("invoice_number")] string InvoiceNumber,
    [property: JsonPropertyName("erp_reference")] string ErpReference,
    [property: JsonPropertyName("occurred_at")] DateTimeOffset OccurredAt,
    [property: JsonPropertyName("reason"), JsonIgnore(Condition = JsonIgnoreCondition.WhenWritingNull)] string? Reason);

/// <summary>
/// Decides which events a saved invoice gets and when: invoice.received after FirstEvent seconds, then the decision
/// (approved / rejected by ApprovalRate) after SecondEvent seconds more. Uses its own RNG seeded from Simulator:Seed,
/// so it does not shift the behavior sequence of POST /api/v1/invoices.
/// </summary>
public sealed class WebhookPlanner
{
    private readonly Lock _lock = new();
    private readonly Random _random;
    private readonly WebhookOptions _options;

    public WebhookPlanner(IOptions<WebhookOptions> options, IOptions<SimulatorOptions> simulator)
    {
        _options = options.Value;
        _random = new Random(unchecked(simulator.Value.Seed * 31 + 7));
    }

    public IReadOnlyList<WebhookDelivery> Plan(ErpInvoice invoice, DateTimeOffset savedAt)
    {
        lock (_lock)
        {
            var receivedAt = savedAt + Seconds(_options.FirstEventMinSeconds, _options.FirstEventMaxSeconds);
            var decidedAt = receivedAt + Seconds(_options.SecondEventMinSeconds, _options.SecondEventMaxSeconds);
            var approved = _random.NextDouble() * 100 < _options.ApprovalRate;
            var reason = approved ? null : _options.RejectReasons[_random.Next(_options.RejectReasons.Length)];

            return
            [
                New(invoice, ErpEventType.Received, receivedAt, null, savedAt),
                New(invoice, approved ? ErpEventType.Approved : ErpEventType.Rejected, decidedAt, reason, savedAt)
            ];
        }
    }

    /// <summary>Whole milliseconds in [min, max] seconds.</summary>
    private TimeSpan Seconds(int min, int max) =>
        TimeSpan.FromMilliseconds(_random.NextInt64(min * 1000L, max * 1000L + 1));

    private static WebhookDelivery New(ErpInvoice invoice, string type, DateTimeOffset at, string? reason, DateTimeOffset now)
    {
        var eventId = $"evt-{Guid.NewGuid():N}";
        var body = new ErpEventBody(eventId, type, invoice.InvoiceNumber, invoice.ErpReference, at, reason);
        return new WebhookDelivery
        {
            EventId = eventId,
            EventType = type,
            InvoiceId = invoice.Id,
            InvoiceNumber = invoice.InvoiceNumber,
            Kind = DeliveryKind.Normal,
            Payload = JsonSerializer.Serialize(body),
            OccurredAt = at,
            DueAt = at,
            Status = DeliveryStatus.Pending,
            CreatedAt = now
        };
    }
}
