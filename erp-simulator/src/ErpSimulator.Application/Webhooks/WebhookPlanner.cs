using System.Text.Json;
using System.Text.Json.Serialization;
using ErpSimulator.Domain.Invoices;
using ErpSimulator.Domain.Webhooks;
using ErpSimulator.Application.Simulation;
using Microsoft.Extensions.Options;

namespace ErpSimulator.Application.Webhooks;

/// <summary>The event body as the invoice service expects it (snake_case; reason only on invoice.rejected).</summary>
public sealed record ErpEventBody(
    [property: JsonPropertyName("event_id")] string EventId,
    [property: JsonPropertyName("event_type")] string EventType,
    [property: JsonPropertyName("invoice_number")] string InvoiceNumber,
    [property: JsonPropertyName("erp_reference")] string ErpReference,
    [property: JsonPropertyName("occurred_at")] DateTimeOffset OccurredAt,
    [property: JsonPropertyName("reason"), JsonIgnore(Condition = JsonIgnoreCondition.WhenWritingNull)] string? Reason);

/// <summary>The event body of an invoice received with API v2: a named schema, camelCase, the invoice as an object.</summary>
public sealed record ErpEventBodyV2(
    [property: JsonPropertyName("schema")] string Schema,
    [property: JsonPropertyName("id")] string Id,
    [property: JsonPropertyName("type")] string Type,
    [property: JsonPropertyName("occurredAt")] DateTimeOffset OccurredAt,
    [property: JsonPropertyName("invoice")] ErpEventInvoiceV2 Invoice,
    [property: JsonPropertyName("reason"), JsonIgnore(Condition = JsonIgnoreCondition.WhenWritingNull)] string? Reason)
{
    public const string SchemaName = "erp.invoice-event.v2";
}

public sealed record ErpEventInvoiceV2(
    [property: JsonPropertyName("number")] string Number,
    [property: JsonPropertyName("erpReference")] string ErpReference);

/// <summary>
/// Plans the events of a saved invoice: invoice.received, then the decision, plus the deliberate problems (order mix,
/// lost decision, duplicate, fake, replay), each drawn independently. Uses its own seeded RNG, so it does not change
/// the behavior sequence of POST /api/v1/invoices.
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
        if (!_options.Enabled)
            return [];

        lock (_lock)
        {
            var settings = _options;
            var problems = settings.Problems;

            var receivedAt = savedAt + Seconds(settings.FirstEventMinSeconds, settings.FirstEventMaxSeconds);
            var decidedAt = receivedAt + Seconds(settings.SecondEventMinSeconds, settings.SecondEventMaxSeconds);
            var approved = Chance(settings.ApprovalRate);
            var reason = settings.RejectReasons[_random.Next(settings.RejectReasons.Length)];
            var orderMix = Chance(problems.OrderMixRate);
            var decisionLost = Chance(problems.LostDecisionRate);
            var duplicateReceived = Chance(problems.DuplicateRate);
            var duplicateReceivedDelay = Seconds(0, 2);
            var duplicateDecision = Chance(problems.DuplicateRate);
            var duplicateDecisionDelay = Seconds(0, 2);
            var fake = Chance(problems.FakeRate);
            var fakeApproved = Chance(50);
            var fakeAt = savedAt + Seconds(settings.FirstEventMinSeconds, settings.FirstEventMaxSeconds + settings.SecondEventMaxSeconds);
            var replay = Chance(problems.ReplayRate);
            var replayDecision = Chance(50);
            var replayDelay = Seconds(1, 5);
            var receivedFraction = _random.NextDouble();

            // Only send times swap: invoice.received occurred earlier but was delayed in transit.
            // The fraction is drawn for every invoice, even when there is nothing to reorder.
            var receivedOccurredAt = receivedAt;
            if (orderMix && !decisionLost)
            {
                (receivedAt, decidedAt) = (decidedAt, receivedAt);
                receivedOccurredAt = savedAt.AddTicks((long)((decidedAt - savedAt).Ticks * receivedFraction));
            }

            var received = CreateDelivery(invoice, ErpEventType.Received, receivedAt, receivedOccurredAt, null, DeliveryKind.Normal, savedAt);
            var decision = CreateDelivery(invoice, approved ? ErpEventType.Approved : ErpEventType.Rejected, decidedAt, decidedAt,
                approved ? null : reason, decisionLost ? DeliveryKind.LostDecision : DeliveryKind.Normal, savedAt);
            if (decisionLost)
                decision.Status = DeliveryStatus.Skipped;

            var rows = new List<WebhookDelivery> { received, decision };

            if (duplicateReceived)
                rows.Add(CopyDelivery(received, DeliveryKind.Duplicate, receivedAt + duplicateReceivedDelay));
            if (duplicateDecision && !decisionLost)
                rows.Add(CopyDelivery(decision, DeliveryKind.Duplicate, decidedAt + duplicateDecisionDelay));

            if (fake)
            {
                rows.Add(CreateDelivery(invoice, fakeApproved ? ErpEventType.Approved : ErpEventType.Rejected, fakeAt, fakeAt,
                    fakeApproved ? null : reason, DeliveryKind.Fake, savedAt));
            }

            if (replay)
            {
                // A lost decision was never sent, so it cannot be "sent again": the received event is replayed instead.
                var original = replayDecision && !decisionLost ? decision : received;
                var replayRow = CopyDelivery(original, DeliveryKind.Replay, original.DueAt + replayDelay);
                replayRow.Status = DeliveryStatus.Waiting;
                rows.Add(replayRow);
            }

            return rows;
        }
    }

    /// <summary>
    /// Plans a cancellation's events: invoice.cancelled, plus its order mix, lost event and duplicate, each drawn
    /// independently. With an order mix, an approval still to come (<paramref name="planned"/>) gets a new event: made just
    /// before the cancellation, sent after invoice.cancelled. The rows planned for later never go out
    /// (<see cref="Abstractions.IErpInvoiceStore.SaveCancellationAsync"/>).
    /// </summary>
    public IReadOnlyList<WebhookDelivery> PlanCancellation(
        ErpInvoice invoice, DateTimeOffset cancelledAt, IReadOnlyList<WebhookDelivery> planned)
    {
        if (!_options.Enabled)
            return [];

        lock (_lock)
        {
            var settings = _options;
            var problems = settings.Problems;

            var dueAt = cancelledAt + Seconds(settings.FirstEventMinSeconds, settings.FirstEventMaxSeconds);
            var lost = Chance(problems.LostDecisionRate);
            var orderMix = Chance(problems.OrderMixRate);
            var duplicate = Chance(problems.DuplicateRate);
            var duplicateDelay = Seconds(0, 2);
            var approvalDelay = Seconds(settings.SecondEventMinSeconds, settings.SecondEventMaxSeconds);

            var cancelled = CreateDelivery(invoice, ErpEventType.Cancelled, dueAt, cancelledAt, null,
                lost ? DeliveryKind.LostDecision : DeliveryKind.Normal, cancelledAt);
            if (lost)
            {
                cancelled.Status = DeliveryStatus.Skipped;
                return [cancelled];
            }

            var rows = new List<WebhookDelivery> { cancelled };
            if (duplicate)
                rows.Add(CopyDelivery(cancelled, DeliveryKind.Duplicate, dueAt + duplicateDelay));

            var approvalToCome = planned.Any(d => d.EventType == ErpEventType.Approved && d.Kind == DeliveryKind.Normal && d.OccurredAt > cancelledAt);
            if (orderMix && approvalToCome)
            {
                rows.Add(CreateDelivery(invoice, ErpEventType.Approved, dueAt + approvalDelay, cancelledAt.AddMilliseconds(-1), null,
                    DeliveryKind.Normal, cancelledAt));
            }

            return rows;
        }
    }

    private bool Chance(double percent) => _random.NextDouble() * 100 < percent;

    /// <summary>Whole milliseconds in [min, max] seconds.</summary>
    private TimeSpan Seconds(int min, int max) =>
        TimeSpan.FromMilliseconds(_random.NextInt64(min * 1000L, max * 1000L + 1));

    private static WebhookDelivery CreateDelivery(
        ErpInvoice invoice, string type, DateTimeOffset dueAt, DateTimeOffset occurredAt, string? reason, string kind, DateTimeOffset now)
    {
        var eventId = $"evt-{Guid.NewGuid():N}";
        var payload = invoice.ApiVersion == ErpApiVersion.V2
            ? JsonSerializer.Serialize(new ErpEventBodyV2(ErpEventBodyV2.SchemaName, eventId, type, occurredAt,
                new ErpEventInvoiceV2(invoice.InvoiceNumber, invoice.ErpReference), reason))
            : JsonSerializer.Serialize(new ErpEventBody(eventId, type, invoice.InvoiceNumber, invoice.ErpReference, occurredAt, reason));
        return new WebhookDelivery
        {
            EventId = eventId,
            EventType = type,
            InvoiceId = invoice.Id,
            InvoiceNumber = invoice.InvoiceNumber,
            Kind = kind,
            Payload = payload,
            OccurredAt = occurredAt,
            DueAt = dueAt,
            Status = DeliveryStatus.Pending,
            CreatedAt = now
        };
    }

    /// <summary>The same event (event_id, body) as another row, sent at <paramref name="dueAt"/>.</summary>
    private static WebhookDelivery CopyDelivery(WebhookDelivery original, string kind, DateTimeOffset dueAt) => new()
    {
        EventId = original.EventId,
        EventType = original.EventType,
        InvoiceId = original.InvoiceId,
        InvoiceNumber = original.InvoiceNumber,
        Kind = kind,
        Payload = original.Payload,
        OccurredAt = original.OccurredAt,
        DueAt = dueAt,
        Status = DeliveryStatus.Pending,
        CreatedAt = original.CreatedAt
    };
}
