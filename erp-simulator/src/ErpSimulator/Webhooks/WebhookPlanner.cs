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
/// (approved / rejected by ApprovalRate) after SecondEvent seconds more; then the deliberate problems
/// (Webhooks:Problems), each drawn on its own:
/// <list type="bullet">
/// <item>order mix (per invoice): the two events swap times, so the decision is sent first (not when the decision is
/// lost: with no decision to send there is nothing to reorder, and invoice.received keeps its 2-10 s time);</item>
/// <item>lost decision (per invoice): the decision is written as Skipped and never sent;</item>
/// <item>duplicate (per sent event): a second row with the same event_id and body, 0-2 s later;</item>
/// <item>fake (per invoice): a decision with its own event_id, signed with a wrong key at send time;</item>
/// <item>replay (per invoice): one of its events again, 1-5 s after it, with an old timestamp (signed for it).</item>
/// </list>
/// Uses its own RNG seeded from Simulator:Seed, so it does not shift the behavior sequence of POST /api/v1/invoices.
/// Every invoice consumes the same number of draws, whatever was picked.
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
            var o = _options;
            var p = o.Problems;

            var receivedAt = savedAt + Seconds(o.FirstEventMinSeconds, o.FirstEventMaxSeconds);
            var decidedAt = receivedAt + Seconds(o.SecondEventMinSeconds, o.SecondEventMaxSeconds);
            var approved = Chance(o.ApprovalRate);
            var reason = o.RejectReasons[_random.Next(o.RejectReasons.Length)];
            var orderMix = Chance(p.OrderMixRate);
            var lost = Chance(p.LostDecisionRate);
            var duplicateReceived = Chance(p.DuplicateRate);
            var duplicateReceivedDelay = Seconds(0, 2);
            var duplicateDecision = Chance(p.DuplicateRate);
            var duplicateDecisionDelay = Seconds(0, 2);
            var fake = Chance(p.FakeRate);
            var fakeApproved = Chance(50);
            var fakeAt = savedAt + Seconds(o.FirstEventMinSeconds, o.FirstEventMaxSeconds + o.SecondEventMaxSeconds);
            var replay = Chance(p.ReplayRate);
            var replayDecision = Chance(50);
            var replayDelay = Seconds(1, 5);

            // Order mix: the decision takes invoice.received's time and the other way round. Still drawn for every invoice
            // (independent of the other problems), but it has nothing to reorder when the decision is never sent.
            if (orderMix && !lost)
                (receivedAt, decidedAt) = (decidedAt, receivedAt);

            var received = New(invoice, ErpEventType.Received, receivedAt, null, DeliveryKind.Normal, savedAt);
            var decision = New(invoice, approved ? ErpEventType.Approved : ErpEventType.Rejected, decidedAt,
                approved ? null : reason, lost ? DeliveryKind.LostDecision : DeliveryKind.Normal, savedAt);
            if (lost)
                decision.Status = DeliveryStatus.Skipped;

            var rows = new List<WebhookDelivery> { received, decision };

            if (duplicateReceived)
                rows.Add(Copy(received, DeliveryKind.Duplicate, receivedAt + duplicateReceivedDelay));
            if (duplicateDecision && !lost)
                rows.Add(Copy(decision, DeliveryKind.Duplicate, decidedAt + duplicateDecisionDelay));

            if (fake)
            {
                rows.Add(New(invoice, fakeApproved ? ErpEventType.Approved : ErpEventType.Rejected, fakeAt,
                    fakeApproved ? null : reason, DeliveryKind.Fake, savedAt));
            }

            if (replay)
            {
                // A lost decision was never sent, so it cannot be "sent again": the received event is replayed instead.
                var original = replayDecision && !lost ? decision : received;
                rows.Add(Copy(original, DeliveryKind.Replay, original.DueAt + replayDelay));
            }

            return rows;
        }
    }

    private bool Chance(double percent) => _random.NextDouble() * 100 < percent;

    /// <summary>Whole milliseconds in [min, max] seconds.</summary>
    private TimeSpan Seconds(int min, int max) =>
        TimeSpan.FromMilliseconds(_random.NextInt64(min * 1000L, max * 1000L + 1));

    private static WebhookDelivery New(
        ErpInvoice invoice, string type, DateTimeOffset at, string? reason, string kind, DateTimeOffset now)
    {
        var eventId = $"evt-{Guid.NewGuid():N}";
        var body = new ErpEventBody(eventId, type, invoice.InvoiceNumber, invoice.ErpReference, at, reason);
        return new WebhookDelivery
        {
            EventId = eventId,
            EventType = type,
            InvoiceId = invoice.Id,
            InvoiceNumber = invoice.InvoiceNumber,
            Kind = kind,
            Payload = JsonSerializer.Serialize(body),
            OccurredAt = at,
            DueAt = at,
            Status = DeliveryStatus.Pending,
            CreatedAt = now
        };
    }

    /// <summary>The same event (event_id, body) as another row, sent at <paramref name="dueAt"/>.</summary>
    private static WebhookDelivery Copy(WebhookDelivery original, string kind, DateTimeOffset dueAt) => new()
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
