using InvoiceService.Application.Abstractions;
using InvoiceService.Application.Invoices;
using InvoiceService.Application.Metrics;
using InvoiceService.Application.Outbox;
using InvoiceService.Application.Tests.Fakes;
using InvoiceService.Domain.Invoices;
using InvoiceService.Domain.Reconciliation;
using InvoiceService.Domain.Webhooks;
using Microsoft.Extensions.Diagnostics.Metrics.Testing;
using Microsoft.Extensions.Logging.Abstractions;

namespace InvoiceService.Application.Tests;

/// <summary>What the use cases record, and the values the gauges take from the last database reading.</summary>
public class InvoiceMetricsTests
{
    private const string Number = "FTR-000001";
    private readonly Scenario _s = new();

    private MetricCollector<T> Collect<T>(string instrument) where T : struct =>
        new(_s.MeterFactory, InvoiceMetrics.MeterName, instrument);

    private static ClaimedEntry Entry(int attempt) => new(1, Number, attempt, false, Guid.NewGuid());

    private static ErpSendResult NoAnswer(ErpNoAnswer why) => new(false, null, null, "no answer", TimeSpan.Zero, NoAnswer: why);

    public static TheoryData<ErpSendResult, string?> PostResults => new()
    {
        { FakeErpGateway.Accepted("ERP-1"), SendAttemptResult.Accepted },
        { new ErpSendResult(false, null, 429, "busy", TimeSpan.Zero), SendAttemptResult.Busy },
        { FakeErpGateway.ServerError(), SendAttemptResult.ServerError },
        { NoAnswer(ErpNoAnswer.Timeout), SendAttemptResult.Timeout },
        { NoAnswer(ErpNoAnswer.Unreachable), SendAttemptResult.Unreachable },
        { new ErpSendResult(false, null, 400, "bad request", TimeSpan.Zero), null },
        { new ErpSendResult(false, null, 202, "no reference", TimeSpan.Zero), null }
    };

    [Theory]
    [MemberData(nameof(PostResults))]
    public void A_POST_is_labelled_by_its_answer(ErpSendResult result, string? expected) =>
        Assert.Equal(expected, SendAttemptResult.Of(new SendAttempt(result, SendPath.First)));

    [Fact]
    public void An_attempt_that_found_the_invoice_at_the_ERP_is_already_exists() =>
        Assert.Equal(SendAttemptResult.AlreadyExists,
            SendAttemptResult.Of(new SendAttempt(FakeErpGateway.Accepted("ERP-1"), SendPath.Found)));

    [Theory]
    [InlineData(ErpNoAnswer.Timeout, SendAttemptResult.Timeout)]
    [InlineData(ErpNoAnswer.Unreachable, SendAttemptResult.Unreachable)]
    public async Task An_attempt_whose_question_got_no_answer_is_counted_as_that(ErpNoAnswer why, string expected)
    {
        using var attempts = Collect<long>("erp.send.attempts");
        _s.Invoices.Add(Number, InvoiceStatus.Pending, sendAttempts: 2);
        _s.Erp.LookupResults.Enqueue(new ErpLookupResult(ErpLookup.Unknown, null, null, "no answer", TimeSpan.Zero, NoAnswer: why));

        await _s.OutboxProcessor().SendAsync(Entry(2), "worker-1");

        var measurement = Assert.Single(attempts.GetMeasurementSnapshot());
        Assert.Equal(expected, measurement.Tags["result"]);
    }

    [Fact]
    public async Task Each_attempt_is_counted_once_with_its_result_and_only_POSTs_have_a_duration_and_a_turn()
    {
        using var attempts = Collect<long>("erp.send.attempts");
        using var durations = Collect<double>("erp.send.duration");
        using var turns = Collect<double>("erp.send.pace_wait");
        _s.Invoices.Add(Number, InvoiceStatus.Pending, sendAttempts: 1);
        _s.Erp.SendResults.Enqueue(FakeErpGateway.ServerError() with { Elapsed = TimeSpan.FromMilliseconds(120) });
        await _s.OutboxProcessor().SendAsync(Entry(1), "worker-1");

        _s.Invoices.Invoices[Number].SendAttemptCount = 2;
        _s.Erp.LookupResults.Enqueue(FakeErpGateway.Found("ERP-7"));
        await _s.OutboxProcessor().SendAsync(Entry(2), "worker-1");

        Assert.Equal([SendAttemptResult.ServerError, SendAttemptResult.AlreadyExists],
            attempts.GetMeasurementSnapshot().Select(m => m.Tags["result"]));
        Assert.Equal([0.12], durations.GetMeasurementSnapshot().Select(m => m.Value));
        Assert.Single(turns.GetMeasurementSnapshot());
    }

    [Fact]
    public async Task A_created_invoice_is_counted_and_a_rejected_request_is_not()
    {
        using var created = Collect<long>("invoices.created");
        var handler = _s.CreateInvoiceHandler();

        await handler.HandleAsync(new CreateInvoiceRequest("C-001", 10m, "TRY", new DateOnly(2026, 10, 1)));
        await handler.HandleAsync(new CreateInvoiceRequest("", -5, "lira", null));

        Assert.Equal(1, created.GetMeasurementSnapshot().Sum(m => m.Value));
    }

    [Fact]
    public async Task A_completed_run_is_counted_with_its_duration_and_its_findings_by_type()
    {
        using var runs = Collect<long>("reconciliation.runs");
        using var durations = Collect<double>("reconciliation.duration");
        using var findings = Collect<long>("reconciliation.findings");
        var invoice = _s.Invoices.Add("F-1", InvoiceStatus.Failed);
        invoice.CreatedAt = Scenario.Start.AddHours(-1);
        _s.Erp.ListResult = new ErpListResult(true,
        [
            new ErpRecord("F-1", "ERP-1", "C-001", 10.50m, "TRY", new DateOnly(2026, 10, 1), Scenario.Start.AddHours(-1)),
            new ErpRecord("X-1", "ERP-5", "C-001", 10.50m, "TRY", new DateOnly(2026, 10, 1), Scenario.Start.AddHours(-1))
        ], null);
        _s.Erp.LookupResults.Enqueue(new ErpLookupResult(ErpLookup.Found, "ERP-1", 200, null, TimeSpan.Zero, new ErpDecision(ErpDecisionKind.None)));

        var run = await _s.Reconciliation.StartRunAsync(Scenario.Start, ReconciliationRun.Schedule, default);
        await _s.ReconciliationRunner().RunAsync(run, CancellationToken.None);

        Assert.Equal(ReconciliationStatus.Completed, Assert.Single(runs.GetMeasurementSnapshot()).Tags["status"]);
        Assert.Single(durations.GetMeasurementSnapshot());
        var counted = findings.GetMeasurementSnapshot().Select(m => (string)m.Tags["type"]!).Order().ToList();
        var stored = _s.Reconciliation.Findings.Select(f => f.FindingType).Order().ToList();
        Assert.Equal(stored, counted);
        Assert.Contains(FindingType.FailedButInErp, counted);
        Assert.Contains(FindingType.MissingInService, counted);
    }

    [Fact]
    public async Task A_failed_run_is_counted_as_Basarisiz()
    {
        using var runs = Collect<long>("reconciliation.runs");
        _s.Erp.ListResult = new ErpListResult(false, [], "ERP kayıtları listelenemedi");

        var run = await _s.Reconciliation.StartRunAsync(Scenario.Start, ReconciliationRun.Schedule, default);
        await _s.ReconciliationRunner().RunAsync(run, CancellationToken.None);

        Assert.Equal(ReconciliationStatus.Failed, Assert.Single(runs.GetMeasurementSnapshot()).Tags["status"]);
    }

    [Theory]
    [InlineData(WebhookEventStatus.Processed, WebhookResult.Processed)]
    [InlineData(WebhookEventStatus.Pending, WebhookResult.Waiting)]
    [InlineData(WebhookEventStatus.Ignored, WebhookResult.Ignored)]
    public void An_event_is_labelled_by_the_status_it_was_stored_with(string status, string expected) =>
        Assert.Equal(expected, WebhookResult.Of(status));

    [Fact]
    public void Starting_at_zero_records_every_result_label_with_0()
    {
        using var attempts = Collect<long>("erp.send.attempts");
        using var webhooks = Collect<long>("erp_webhooks.received");

        _s.Metrics.StartAtZero();

        Assert.Equal(SendAttemptResult.All.Order(), attempts.GetMeasurementSnapshot().Select(m => (string)m.Tags["result"]!).Order());
        Assert.Equal(WebhookResult.All.Order(), webhooks.GetMeasurementSnapshot().Select(m => (string)m.Tags["result"]!).Order());
        Assert.All(attempts.GetMeasurementSnapshot().Concat(webhooks.GetMeasurementSnapshot()), m => Assert.Equal(0, m.Value));
    }

    [Fact]
    public void The_gauges_have_no_value_before_the_first_database_reading()
    {
        using var queued = Collect<long>("outbox.queued");
        using var lastCompleted = Collect<double>("reconciliation.last_completed_time");

        queued.RecordObservableInstruments();
        lastCompleted.RecordObservableInstruments();

        Assert.Empty(queued.GetMeasurementSnapshot());
        Assert.Empty(lastCompleted.GetMeasurementSnapshot());
    }

    [Fact]
    public async Task The_gauges_show_the_last_reading_which_has_the_numbers_of_the_summary()
    {
        using var queued = Collect<long>("outbox.queued");
        using var oldest = Collect<double>("outbox.oldest_wait");
        using var byStatus = Collect<long>("invoices.by_status");
        using var stuck = Collect<long>("invoices.stuck");
        using var lastCompleted = Collect<double>("reconciliation.last_completed_time");
        _s.Invoices.Add("F-1", InvoiceStatus.Pending);
        var finished = Scenario.Start.AddMinutes(-30);
        _s.Reconciliation.Runs.Add(new ReconciliationRun
        {
            Id = 1, StartedAt = finished.AddSeconds(-4), FinishedAt = finished, Status = ReconciliationStatus.Completed
        });
        _s.Reconciliation.Runs.Add(new ReconciliationRun
        {
            Id = 2, StartedAt = Scenario.Start.AddMinutes(-1), FinishedAt = Scenario.Start, Status = ReconciliationStatus.Failed
        });

        await new DatabaseMetricsReader(_s.InvoiceQueries(), _s.Reconciliation, _s.DatabaseMetrics,
            NullLogger<DatabaseMetricsReader>.Instance).ReadAsync(CancellationToken.None);
        var summary = await _s.InvoiceQueries().SummaryAsync(CancellationToken.None);
        queued.RecordObservableInstruments();
        byStatus.RecordObservableInstruments();
        stuck.RecordObservableInstruments();
        oldest.RecordObservableInstruments();
        lastCompleted.RecordObservableInstruments();

        Assert.Equal(summary.QueuedCount, queued.LastMeasurement!.Value);
        Assert.Equal(summary.OldestQueuedSeconds ?? 0, oldest.LastMeasurement!.Value);
        Assert.Equal(summary.StuckCount, stuck.LastMeasurement!.Value);
        Assert.Equal(summary.Counts.ToDictionary(c => c.Status, c => (long)c.Count),
            byStatus.GetMeasurementSnapshot().ToDictionary(m => (string)m.Tags["status"]!, m => m.Value));
        Assert.Equal(finished.ToUnixTimeSeconds(), lastCompleted.LastMeasurement!.Value);
    }

    /// <summary>The reader clears the reading when it fails.</summary>
    [Fact]
    public void A_cleared_reading_leaves_the_gauges_without_a_value_rather_than_the_old_one()
    {
        using var queued = Collect<long>("outbox.queued");
        _s.DatabaseMetrics.Set(new DatabaseReading(
            new InvoiceSummary([], 0, 0, 2, 5, 60, 0), null));
        _s.DatabaseMetrics.Set(null);

        queued.RecordObservableInstruments();

        Assert.Empty(queued.GetMeasurementSnapshot());
    }
}
