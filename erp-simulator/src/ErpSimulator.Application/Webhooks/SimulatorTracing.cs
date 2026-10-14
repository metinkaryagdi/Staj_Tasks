using System.Diagnostics;
using ErpSimulator.Domain.Webhooks;

namespace ErpSimulator.Application.Webhooks;

/// <summary>
/// The span the simulator opens itself (webhook.send; HTTP, HttpClient and database spans come from OpenTelemetry's
/// instrumentation). Only System.Diagnostics: the Api registers the source with OpenTelemetry.
/// </summary>
public static class SimulatorTracing
{
    public const string SourceName = "ErpSimulator";

    public static readonly ActivitySource Source = new(SourceName);

    /// <summary>The same attribute name as the invoice service's, so one search finds both services' spans.</summary>
    public const string InvoiceNumber = "invoice.number";

    /// <summary>
    /// Starts the send of a delivery in the trace of its stored W3C traceparent; without a valid one, a new trace (never
    /// under whatever span happens to be current).
    /// </summary>
    public static Activity? StartSend(WebhookDelivery delivery)
    {
        var parent = ActivityContext.TryParse(delivery.TraceParent, null, out var context) ? context : default;
        // With no parent, StartActivity falls back to Activity.Current: cleared so the span is a root instead.
        Activity.Current = null;
        var activity = Source.StartActivity("webhook.send", ActivityKind.Internal, parent);
        activity?.SetTag(InvoiceNumber, delivery.InvoiceNumber);
        activity?.SetTag("erp_event.id", delivery.EventId);
        activity?.SetTag("erp_event.type", delivery.EventType);
        activity?.SetTag("webhook.kind", delivery.Kind);
        return activity;
    }
}

