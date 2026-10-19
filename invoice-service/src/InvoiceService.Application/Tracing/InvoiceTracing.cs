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

    /// <summary>
    /// Starts the invoice's trace with its time in the queue: a root span from <paramref name="createdAt"/> (the entry
    /// entered the queue) to <paramref name="takenAt"/> (the worker took it for the first time), recorded later, backdated.
    /// The attempts go under it. Its end is set here; the caller stops it.
    /// </summary>
    public static Activity? StartQueueWait(string invoiceNumber, DateTimeOffset createdAt, DateTimeOffset takenAt)
    {
        var span = StartInTrace("outbox.queue_wait", null, createdAt);
        span?.SetTag(InvoiceNumber, invoiceNumber);
        span?.SetTag("outbox.queue_wait_seconds", Math.Max(0, (takenAt - createdAt).TotalSeconds));
        span?.SetEndTime(takenAt.UtcDateTime);
        return span;
    }

    /// <summary>
    /// Records a step taken on the invoice outside its own requests and attempts (a reconciliation fix, an operator's
    /// resend) as a span in the invoice's trace, from <paramref name="started"/> until now, so the trace shows the
    /// journey to its end. Nothing is recorded for an invoice without a stored traceparent (queued before tracing). The
    /// caller's current span stays current.
    /// </summary>
    public static void RecordStep(
        string name, string? traceParent, string invoiceNumber, DateTimeOffset started, params (string Key, object? Value)[] tags)
    {
        if (!ActivityContext.TryParse(traceParent, null, out _))
            return;
        var previous = Activity.Current;
        try
        {
            using var span = StartInTrace(name, traceParent, started);
            span?.SetTag(InvoiceNumber, invoiceNumber);
            foreach (var (key, value) in tags)
                span?.SetTag(key, value);
        }
        finally
        {
            Activity.Current = previous;
        }
    }
}
