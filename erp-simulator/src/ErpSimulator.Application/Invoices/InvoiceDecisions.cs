using System.Text.Json;
using ErpSimulator.Application.Webhooks;
using ErpSimulator.Domain.Webhooks;

namespace ErpSimulator.Application.Invoices;

public static class DecisionKind
{
    /// <summary>The ERP has not reached invoice.received yet.</summary>
    public const string None = "none";
    public const string Received = "received";
    public const string Approved = "approved";
    public const string Rejected = "rejected";
}

/// <param name="Kind">One of <see cref="DecisionKind"/>.</param>
/// <param name="Reason">The rejection reason; only when rejected.</param>
/// <param name="DecidedAt">When the decision was made; only when approved or rejected.</param>
public sealed record InvoiceDecision(string Kind, string? Reason = null, DateTimeOffset? DecidedAt = null)
{
    public static readonly InvoiceDecision None = new(DecisionKind.None);
}

public static class InvoiceDecisions
{
    /// <summary>
    /// What the ERP has decided about one record by <paramref name="now"/>, from the events planned for it. An event
    /// counts once its time has come, whether or not it was ever sent (a lost decision still counts).
    /// </summary>
    public static InvoiceDecision Resolve(IEnumerable<WebhookDelivery> deliveries, DateTimeOffset now)
    {
        // Fake, replayed and duplicated rows are not the ERP's own events.
        var happened = deliveries
            .Where(d => d.Kind is DeliveryKind.Normal or DeliveryKind.LostDecision && d.OccurredAt <= now)
            .ToList();

        var decision = happened.FirstOrDefault(d => d.EventType is ErpEventType.Approved or ErpEventType.Rejected);
        if (decision is null)
            return happened.Any(d => d.EventType == ErpEventType.Received) ? new(DecisionKind.Received) : InvoiceDecision.None;

        return decision.EventType == ErpEventType.Approved
            ? new(DecisionKind.Approved, DecidedAt: decision.OccurredAt)
            : new(DecisionKind.Rejected, ReadReason(decision.Payload), decision.OccurredAt);
    }

    private static string? ReadReason(string payload) => JsonSerializer.Deserialize<ErpEventBody>(payload)?.Reason;
}
