using System.Diagnostics;

namespace InvoiceService.Application.Tracing;

/// <summary>
/// The spans the service opens itself (HTTP, HttpClient and database spans come from OpenTelemetry's instrumentation) and
/// the attribute names they carry. Like the metrics, only System.Diagnostics: the Api registers the source with
/// OpenTelemetry.
/// </summary>
public static class InvoiceTracing
{
    public const string SourceName = "InvoiceService";

    public static readonly ActivitySource Source = new(SourceName);

    /// <summary>On every span about one invoice, so its trace can be found by invoice number.</summary>
    public const string InvoiceNumber = "invoice.number";

    /// <summary>
    /// Starts a span in the trace of <paramref name="traceParent"/> (a stored W3C traceparent). Without a valid one it
    /// starts a new trace, never under whatever span happens to be current.
    /// </summary>
    public static Activity? StartInTrace(
        string name, string? traceParent, DateTimeOffset startTime = default)
    {
        var parent = ActivityContext.TryParse(traceParent, null, out var context) ? context : default;
        // With no parent, StartActivity falls back to Activity.Current: cleared so the span is a root instead.
        Activity.Current = null;
        return Source.StartActivity(name, ActivityKind.Internal, parent, startTime: startTime);
    }
}
