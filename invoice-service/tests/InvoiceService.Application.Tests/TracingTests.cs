using System.Diagnostics;
using InvoiceService.Application.Invoices;
using InvoiceService.Application.Outbox;
using InvoiceService.Application.Tests.Fakes;
using InvoiceService.Application.Tracing;
using InvoiceService.Application.Webhooks;
using InvoiceService.Domain.Invoices;
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
    public async Task A_created_invoice_queues_the_request_s_traceparent_and_names_the_invoice_on_its_span()
    {
        using var request = Current();

        await _s.CreateInvoiceHandler().HandleAsync(new CreateInvoiceRequest("C-001", 10m, "TRY", new DateOnly(2026, 10, 1)));

        var (invoice, entry) = Assert.Single(_s.Invoices.Queued);
        Assert.Equal(request.Id, entry.TraceParent);
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
}
