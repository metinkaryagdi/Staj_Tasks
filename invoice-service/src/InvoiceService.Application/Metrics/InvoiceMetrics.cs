using System.Diagnostics.Metrics;
using InvoiceService.Domain.Reconciliation;

namespace InvoiceService.Application.Metrics;

/// <summary>
/// The service's metrics (meter <see cref="MeterName"/>), exported over OTLP to the Collector, where Prometheus reads
/// them. OpenTelemetry names them with dots; Prometheus shows them with underscores, the unit (_seconds) and, for
/// counters, _total.
/// </summary>
public sealed class InvoiceMetrics
{
    public const string MeterName = "InvoiceService";

    /// <summary>ERP answers take 50-200 ms; a POST is given up after Erp:TimeoutSeconds (10).</summary>
    private static readonly double[] SendDurationBuckets = [0.025, 0.05, 0.075, 0.1, 0.125, 0.15, 0.175, 0.2, 0.25, 0.5, 1, 2.5, 5, 10];

    /// <summary>No wait when the turn is free; under load the queue of turns grows to seconds.</summary>
    private static readonly double[] PaceWaitBuckets = [0, 0.01, 0.05, 0.1, 0.25, 0.5, 1, 2, 5, 10, 30, 60];

    private static readonly double[] RunDurationBuckets = [0.1, 0.25, 0.5, 1, 2.5, 5, 10, 30, 60, 120, 300];

    private readonly Counter<long> _created;
    private readonly Counter<long> _sendAttempts;
    private readonly Histogram<double> _sendDuration;
    private readonly Histogram<double> _paceWait;
    private readonly Counter<long> _webhooks;
    private readonly Counter<long> _runs;
    private readonly Histogram<double> _runDuration;
    private readonly Counter<long> _findings;

    public InvoiceMetrics(IMeterFactory meterFactory, DatabaseMetrics database)
    {
        var meter = meterFactory.Create(MeterName);

        _created = meter.CreateCounter<long>("invoices.created", "{invoice}", "Invoices created (saved with their outbox entry)");
        _sendAttempts = meter.CreateCounter<long>("erp.send.attempts", "{attempt}",
            "Attempts to get an invoice to the ERP, by result");
        _sendDuration = meter.CreateHistogram("erp.send.duration", "s", "How long an invoice POST to the ERP took",
            advice: new InstrumentAdvice<double> { HistogramBucketBoundaries = SendDurationBuckets });
        _paceWait = meter.CreateHistogram("erp.send.pace_wait", "s", "How long a POST waited for its turn under the send rate",
            advice: new InstrumentAdvice<double> { HistogramBucketBoundaries = PaceWaitBuckets });
        _webhooks = meter.CreateCounter<long>("erp_webhooks.received", "{event}", "ERP events received, by result");
        _runs = meter.CreateCounter<long>("reconciliation.runs", "{run}", "Reconciliation runs, by how they ended");
        _runDuration = meter.CreateHistogram("reconciliation.duration", "s", "How long a reconciliation run took",
            advice: new InstrumentAdvice<double> { HistogramBucketBoundaries = RunDurationBuckets });
        _findings = meter.CreateCounter<long>("reconciliation.findings", "{finding}",
            "Reconciliation findings, by type");

        // Read from the last database reading, never from the database: see DatabaseMetrics.
        meter.CreateObservableGauge("outbox.queued", () => Read(database, r => (long)r.Summary.QueuedCount), "{invoice}",
            "Invoices waiting in the queue to the ERP (erp_outbox Bekliyor)");
        meter.CreateObservableGauge("outbox.oldest_wait", () => Read(database, r => (double)(r.Summary.OldestQueuedSeconds ?? 0)), "s",
            "How long the oldest invoice in the queue has waited; 0 when the queue is empty");
        meter.CreateObservableGauge("invoices.by_status", () => ByStatus(database), "{invoice}", "Invoices in each status");
        meter.CreateObservableGauge("invoices.stuck", () => Read(database, r => (long)r.Summary.StuckCount), "{invoice}",
            "Invoices stuck in Gönderildi or İşleme Alındı longer than Reconciliation:StuckAfterMinutes");
        meter.CreateObservableGauge("reconciliation.last_completed_time", () => LastCompleted(database), "s",
            "When the newest Tamamlandı reconciliation run finished, Unix time");
    }

    /// <summary>
    /// Every counter series exists from startup with 0. Prometheus does not count the first value of a series it has not
    /// seen before as an increase: 21 401s arriving before the first export would otherwise show as no increase at all.
    /// Called once the app has started: a measurement made before OpenTelemetry listens is lost, and a worker may create
    /// this class earlier.
    /// </summary>
    public void StartAtZero()
    {
        _created.Add(0);
        foreach (var result in SendAttemptResult.All)
            _sendAttempts.Add(0, new KeyValuePair<string, object?>("result", result));
        foreach (var result in WebhookResult.All)
            _webhooks.Add(0, new KeyValuePair<string, object?>("result", result));
        foreach (var status in new[] { ReconciliationStatus.Completed, ReconciliationStatus.Failed })
            _runs.Add(0, new KeyValuePair<string, object?>("status", status));
        foreach (var type in FindingType.All)
            _findings.Add(0, new KeyValuePair<string, object?>("type", type));
    }

    public void InvoiceCreated() => _created.Add(1);

    public void SendAttempt(string result) => _sendAttempts.Add(1, new KeyValuePair<string, object?>("result", result));

    public void SendDuration(TimeSpan elapsed) => _sendDuration.Record(elapsed.TotalSeconds);

    public void PaceWait(TimeSpan waited) => _paceWait.Record(waited.TotalSeconds);

    public void WebhookReceived(string result) => _webhooks.Add(1, new KeyValuePair<string, object?>("result", result));

    public void RunFinished(string status, TimeSpan elapsed)
    {
        _runs.Add(1, new KeyValuePair<string, object?>("status", status));
        _runDuration.Record(elapsed.TotalSeconds);
    }

    public void Finding(string type) => _findings.Add(1, new KeyValuePair<string, object?>("type", type));

    private static IEnumerable<Measurement<T>> Read<T>(DatabaseMetrics database, Func<DatabaseReading, T> value) where T : struct =>
        database.Last is { } reading ? [new Measurement<T>(value(reading))] : [];

    private static IEnumerable<Measurement<long>> ByStatus(DatabaseMetrics database) =>
        database.Last is { } reading
            ? reading.Summary.Counts.Select(c => new Measurement<long>(c.Count, new KeyValuePair<string, object?>("status", c.Status)))
            : [];

    private static IEnumerable<Measurement<double>> LastCompleted(DatabaseMetrics database) =>
        database.Last?.LastCompletedRunAt is { } at ? [new Measurement<double>(at.ToUnixTimeMilliseconds() / 1000.0)] : [];
}
