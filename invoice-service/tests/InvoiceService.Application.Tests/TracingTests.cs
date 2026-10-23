using System.Diagnostics;
using InvoiceService.Application.Abstractions;
using InvoiceService.Application.Invoices;
using InvoiceService.Application.Outbox;
using InvoiceService.Application.Reconciliation;
using InvoiceService.Application.Tests.Fakes;
using InvoiceService.Application.Tracing;
using InvoiceService.Application.Webhooks;
using InvoiceService.Domain.Invoices;
using InvoiceService.Domain.Operators;
using InvoiceService.Domain.Outbox;
using InvoiceService.Domain.Reconciliation;
using InvoiceService.Domain.Webhooks;

namespace InvoiceService.Application.Tests;

/// <summary>
/// What the use cases put in the trace: the stored traceparent, the attempt's attributes and the events applied to the
/// invoice. The current span is a plain started Activity, as the worker's or the request's would be.
/// </summary>
public sealed class TracingTests : IDisposable
{
    private const string Number = "FTR-000001";
    private readonly Scenario _s = new();
    private readonly ActivityListener _listener = new()
    {
        ShouldListenTo = source => source.Name == InvoiceTracing.SourceName,
        Sample = (ref ActivityCreationOptions<ActivityContext> _) => ActivitySamplingResult.AllDataAndRecorded
    };

    public TracingTests() => ActivitySource.AddActivityListener(_listener);

    public void Dispose() => _listener.Dispose();

    private static Activity Current(string name = "test") => new Activity(name).SetIdFormat(ActivityIdFormat.W3C).Start();

    [Fact]
    public async Task A_created_invoice_names_the_invoice_on_the_request_s_span_and_leaves_its_trace_to_the_worker()
    {
        using var request = Current();

        await _s.CreateInvoiceHandler().HandleAsync(new CreateInvoiceRequest("C-001", 10m, "TRY", new DateOnly(2026, 10, 1)));

        var (invoice, entry) = Assert.Single(_s.Invoices.Queued);
        Assert.Null(entry.TraceParent);
        Assert.Equal(invoice.InvoiceNumber, request.GetTagItem(InvoiceTracing.InvoiceNumber));
    }

    [Fact]
    public async Task An_attempt_that_will_be_retried_carries_its_number_result_and_wait_and_is_an_error()
    {
        _s.Invoices.Add(Number, InvoiceStatus.Pending, sendAttempts: 1);
        _s.Erp.SendResults.Enqueue(FakeErpGateway.ServerError());
        using var attempt = Current();

        await _s.OutboxProcessor().SendAsync(new ClaimedEntry(1, Number, 1, false, Guid.NewGuid()), "worker-1");

        Assert.Equal(Number, attempt.GetTagItem(InvoiceTracing.InvoiceNumber));
        Assert.Equal(1, attempt.GetTagItem("outbox.attempt"));
        Assert.Equal(nameof(SendOutcome.Retry), attempt.GetTagItem("outbox.outcome"));
        Assert.Equal(500, attempt.GetTagItem("erp.http_status"));
        // The same wait the outcome writer gave the entry.
        var outcome = Assert.Single(_s.Outbox.Outcomes);
        Assert.Equal((outcome.NextAttemptAt - Scenario.Start).TotalSeconds, (double)attempt.GetTagItem("outbox.wait_seconds")!);
        Assert.True((double)attempt.GetTagItem("outbox.wait_seconds")! > 0);
        Assert.Equal(ActivityStatusCode.Error, attempt.Status);
    }

    [Fact]
    public async Task A_sent_attempt_is_not_an_error_and_its_POST_waits_for_its_turn_in_a_span_of_its_own()
    {
        _s.Invoices.Add(Number, InvoiceStatus.Pending, sendAttempts: 1);
        _s.Erp.SendResults.Enqueue(FakeErpGateway.Accepted("ERP-1"));
        // Other test classes may run at the same time: only this attempt's children are looked at.
        var stopped = new System.Collections.Concurrent.ConcurrentQueue<Activity>();
        _listener.ActivityStopped = stopped.Enqueue;
        using var attempt = Current();

        await _s.OutboxProcessor().SendAsync(new ClaimedEntry(1, Number, 1, false, Guid.NewGuid()), "worker-1");

        Assert.Equal(nameof(SendOutcome.Sent), attempt.GetTagItem("outbox.outcome"));
        Assert.Equal(0d, attempt.GetTagItem("outbox.wait_seconds"));
        Assert.Equal(ActivityStatusCode.Unset, attempt.Status);
        Assert.Single(stopped, a => a.OperationName == "erp.pace_wait" && a.ParentSpanId == attempt.SpanId);
    }

    [Fact]
    public async Task A_first_attempt_stores_the_trace_it_started_and_sends()
    {
        const string started = "00-0af7651916cd43dd8448eb211c80319c-b7ad6b7169203331-01";
        _s.Invoices.Add(Number, InvoiceStatus.Pending, sendAttempts: 1);
        _s.Erp.SendResults.Enqueue(FakeErpGateway.Accepted("ERP-1"));
        using var attempt = Current();

        await _s.OutboxProcessor().SendAsync(new ClaimedEntry(1, Number, 1, false, Guid.NewGuid()), "worker-1", started);

        Assert.Equal(started, _s.Outbox.StartedTraces[1]);
        Assert.Contains($"POST {Number}", _s.Erp.Calls);
        Assert.Equal(nameof(SendOutcome.Sent), attempt.GetTagItem("outbox.outcome"));
    }

    [Fact]
    public async Task A_first_attempt_whose_trace_cannot_be_stored_does_not_call_the_ERP()
    {
        // The entry was taken again meanwhile: the trace is not stored, so nothing is sent.
        _s.Outbox.Held = false;
        _s.Invoices.Add(Number, InvoiceStatus.Pending, sendAttempts: 1);
        using var attempt = Current();

        await _s.OutboxProcessor().SendAsync(new ClaimedEntry(1, Number, 1, false, Guid.NewGuid()), "worker-1",
            "00-0af7651916cd43dd8448eb211c80319c-b7ad6b7169203331-01");

        Assert.Empty(_s.Outbox.StartedTraces);
        Assert.Empty(_s.Erp.Calls);
        Assert.Empty(_s.Outbox.Outcomes);
        Assert.Equal("NotHeld", attempt.GetTagItem("outbox.outcome"));
    }

    [Fact]
    public async Task An_event_that_waited_for_the_send_shows_on_the_attempt_that_applied_it()
    {
        _s.Invoices.Add(Number, InvoiceStatus.Pending, sendAttempts: 1);
        using (var webhook = Current("webhook"))
        {
            await _s.WebhookEventProcessor().ReceiveAsync(
                new ErpWebhookRequest("e-1", WebhookEventType.Approved, Number, "ERP-1", Scenario.Start, null), "{}", default);
            var stored = Assert.Single(webhook.Events);
            Assert.Equal("erp event stored", stored.Name);
            Assert.Equal(WebhookEventStatus.Pending, stored.Tags.Single(t => t.Key == "erp_event.status").Value);
        }
        _s.Erp.SendResults.Enqueue(FakeErpGateway.Accepted("ERP-1"));
        using var attempt = Current("attempt");

        await _s.OutboxProcessor().SendAsync(new ClaimedEntry(1, Number, 1, false, Guid.NewGuid()), "worker-1");

        var applied = Assert.Single(attempt.Events);
        Assert.Equal("erp event applied-after-send", applied.Name);
        Assert.Equal("e-1", applied.Tags.Single(t => t.Key == "erp_event.id").Value);
        Assert.Equal(WebhookEventStatus.Processed, applied.Tags.Single(t => t.Key == "erp_event.status").Value);
    }

    [Fact]
    public void The_queue_wait_starts_a_new_trace_backdated_to_the_entry_s_creation_and_the_attempt_goes_under_it()
    {
        var createdAt = new DateTimeOffset(2026, 10, 19, 9, 0, 0, TimeSpan.Zero);
        var takenAt = createdAt.AddMinutes(31);
        using var unrelated = Current();

        using var queueWait = InvoiceTracing.StartQueueWait(Number, createdAt, takenAt);
        using var attempt = InvoiceTracing.StartInTrace("outbox.attempt", queueWait!.Id, takenAt);

        Assert.Equal(default, queueWait.ParentSpanId);
        Assert.NotEqual(unrelated.TraceId, queueWait.TraceId);
        Assert.Equal(createdAt.UtcDateTime, queueWait.StartTimeUtc);
        Assert.Equal(TimeSpan.FromMinutes(31), queueWait.Duration);
        Assert.Equal(Number, queueWait.GetTagItem(InvoiceTracing.InvoiceNumber));
        Assert.Equal(31 * 60d, queueWait.GetTagItem("outbox.queue_wait_seconds"));
        Assert.Equal(queueWait.TraceId, attempt!.TraceId);
        Assert.Equal(queueWait.SpanId, attempt.ParentSpanId);
    }

    [Fact]
    public void A_span_started_in_a_stored_trace_continues_it_and_without_one_is_a_new_trace_even_under_another_span()
    {
        const string stored = "00-0af7651916cd43dd8448eb211c80319c-b7ad6b7169203331-01";
        using var unrelated = Current();

        using (var continued = InvoiceTracing.StartInTrace("outbox.attempt", stored))
        {
            Assert.Equal("0af7651916cd43dd8448eb211c80319c", continued!.TraceId.ToHexString());
            Assert.Equal("b7ad6b7169203331", continued.ParentSpanId.ToHexString());
        }

        Activity.Current = unrelated;
        using var root = InvoiceTracing.StartInTrace("outbox.attempt", null);
        Assert.NotEqual(unrelated.TraceId, root!.TraceId);
        Assert.Equal(default, root.ParentSpanId);
    }

    // --- Steps taken on the invoice outside its requests and attempts
    // ---------------------------------------------------------------------------------------------

    private const string StoredTrace = "00-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-01";
    private const string StoredTraceId = "4bf92f3577b34da6a3ce929d0e0e4736";

    private System.Collections.Concurrent.ConcurrentQueue<Activity> CaptureStopped()
    {
        // Other test classes may run at the same time: only spans in this test's stored trace are looked at.
        var stopped = new System.Collections.Concurrent.ConcurrentQueue<Activity>();
        _listener.ActivityStopped = stopped.Enqueue;
        return stopped;
    }

    private void StoreEntry(string number, string? traceParent) =>
        _s.Outbox.Entries[number] = new ErpOutboxEntry { InvoiceNumber = number, Status = OutboxStatus.Failed, TraceParent = traceParent };

    private Task<bool> ApplyDecision(string expectedStatus) => _s.FixApplier().ApplyAsync(7, new PlannedFinding(
        Number, FindingType.StuckInvoice, "ayrıntı",
        new Fix(FixKind.ApplyDecision, Number, expectedStatus, "ERP-1", new ErpDecision(ErpDecisionKind.Approved))));

    [Fact]
    public async Task A_reconciliation_fix_is_a_span_in_the_invoice_s_trace_and_the_caller_s_span_stays_current()
    {
        _s.Invoices.Add(Number, InvoiceStatus.Sent, erpReference: "ERP-1");
        StoreEntry(Number, StoredTrace);
        var stopped = CaptureStopped();
        using var run = Current("reconciliation");

        Assert.True(await ApplyDecision(InvoiceStatus.Sent));

        var fix = Assert.Single(stopped, a => a.OperationName == "reconciliation.fix" && a.TraceId.ToHexString() == StoredTraceId);
        Assert.Equal("00f067aa0ba902b7", fix.ParentSpanId.ToHexString());
        Assert.Equal(Number, fix.GetTagItem(InvoiceTracing.InvoiceNumber));
        Assert.Equal(FindingType.StuckInvoice, fix.GetTagItem("reconciliation.finding_type"));
        Assert.Equal(nameof(FixKind.ApplyDecision), fix.GetTagItem("reconciliation.fix"));
        Assert.Equal(InvoiceStatus.Approved, fix.GetTagItem("invoice.status"));
        Assert.Same(run, Activity.Current);
    }

    [Fact]
    public async Task A_fix_left_alone_because_the_invoice_changed_adds_nothing_to_the_trace()
    {
        _s.Invoices.Add(Number, InvoiceStatus.Approved, erpReference: "ERP-1");
        StoreEntry(Number, StoredTrace);
        var stopped = CaptureStopped();

        Assert.False(await ApplyDecision(InvoiceStatus.Sent));

        Assert.DoesNotContain(stopped, a => a.TraceId.ToHexString() == StoredTraceId);
    }

    [Fact]
    public async Task An_operator_s_resend_is_a_span_in_the_invoice_s_trace_and_the_request_s_span_stays_current()
    {
        _s.Invoices.Add(Number, InvoiceStatus.Failed);
        StoreEntry(Number, StoredTrace);
        var stopped = CaptureStopped();
        using var request = Current("request");

        var result = await _s.ResendInvoiceHandler().HandleAsync(Number, Scenario.Operator("Ayşe"), OperatorActionType.BulkResend);

        Assert.Equal(ResendStatus.Queued, result.Status);
        var resend = Assert.Single(stopped, a => a.OperationName == "invoice.resend" && a.TraceId.ToHexString() == StoredTraceId);
        Assert.Equal("00f067aa0ba902b7", resend.ParentSpanId.ToHexString());
        Assert.Equal(Number, resend.GetTagItem(InvoiceTracing.InvoiceNumber));
        Assert.Equal(OperatorActionType.BulkResend, resend.GetTagItem("operator.action"));
        Assert.Same(request, Activity.Current);
    }

    [Fact]
    public async Task A_step_of_an_invoice_without_a_stored_trace_is_not_recorded()
    {
        const string untraced = "FTR-000042";
        _s.Invoices.Add(untraced, InvoiceStatus.Failed);
        StoreEntry(untraced, null);
        var stopped = CaptureStopped();
        using var request = Current("request");

        await _s.ResendInvoiceHandler().HandleAsync(untraced, Scenario.Operator("Ayşe"));

        Assert.DoesNotContain(stopped, a => a.OperationName == "invoice.resend" && Equals(a.GetTagItem(InvoiceTracing.InvoiceNumber), untraced));
        Assert.Same(request, Activity.Current);
    }
}
