using InvoiceService.Application.Outbox;
using InvoiceService.Application.Tests.Fakes;
using InvoiceService.Application.Webhooks;
using InvoiceService.Domain.Invoices;
using InvoiceService.Domain.Outbox;
using InvoiceService.Domain.Webhooks;

namespace InvoiceService.Application.Tests;

/// <summary>The send flow with the ERP and the database replaced by in-memory ports (no HTTP, no PostgreSQL).</summary>
public class OutboxProcessorTests
{
    private const string Number = "FTR-000001";
    private readonly Scenario _s = new();

    private static ClaimedEntry Entry(int attempt, bool usedUp = false) =>
        new(1, Number, attempt, usedUp, Guid.NewGuid());

    private Task Send(ClaimedEntry entry) => _s.OutboxProcessor().SendAsync(entry, "worker-1");

    [Fact]
    public async Task First_attempt_posts_directly_and_marks_the_invoice_sent()
    {
        _s.Invoices.Add(Number, InvoiceStatus.Pending, sendAttempts: 1);
        _s.Erp.SendResults.Enqueue(FakeErpGateway.Accepted("ERP-1"));

        await Send(Entry(1));

        Assert.Equal(["POST " + Number], _s.Erp.Calls);
        Assert.Equal(InvoiceStatus.Sent, _s.Invoices.Invoices[Number].Status);
        Assert.Equal("ERP-1", _s.Invoices.Invoices[Number].ErpReference);
        var outcome = Assert.Single(_s.Outbox.Outcomes);
        Assert.Equal(OutboxStatus.Completed, outcome.Status);
        Assert.Equal(Scenario.Start, outcome.ProcessedAt);
        Assert.Equal(1, _s.UnitOfWork.Committed);
    }

    [Fact]
    public async Task Later_attempt_takes_the_reference_the_ERP_already_has_without_posting()
    {
        _s.Invoices.Add(Number, InvoiceStatus.Pending, sendAttempts: 2);
        _s.Erp.LookupResults.Enqueue(FakeErpGateway.Found("ERP-7"));

        await Send(Entry(2));

        Assert.Equal(["GET " + Number], _s.Erp.Calls);
        Assert.Equal(InvoiceStatus.Sent, _s.Invoices.Invoices[Number].Status);
        Assert.Equal("ERP-7", _s.Invoices.Invoices[Number].ErpReference);
    }

    [Fact]
    public async Task Later_attempt_posts_only_when_the_ERP_clearly_does_not_have_the_invoice()
    {
        _s.Invoices.Add(Number, InvoiceStatus.Pending, sendAttempts: 2);
        _s.Erp.LookupResults.Enqueue(FakeErpGateway.NotFound());
        _s.Erp.SendResults.Enqueue(FakeErpGateway.Accepted("ERP-2"));

        await Send(Entry(2));

        Assert.Equal(["GET " + Number, "POST " + Number], _s.Erp.Calls);
        Assert.Equal("ERP-2", _s.Invoices.Invoices[Number].ErpReference);
    }

    [Fact]
    public async Task ERP_that_cannot_be_asked_is_not_posted_to_and_the_attempt_is_retried_later()
    {
        _s.Invoices.Add(Number, InvoiceStatus.Pending, sendAttempts: 2);
        _s.Erp.LookupResults.Enqueue(FakeErpGateway.Unknown());

        await Send(Entry(2));

        Assert.Equal(["GET " + Number], _s.Erp.Calls);
        Assert.Equal(InvoiceStatus.Pending, _s.Invoices.Invoices[Number].Status);
        var outcome = Assert.Single(_s.Outbox.Outcomes);
        Assert.Equal(OutboxStatus.Pending, outcome.Status);
        Assert.True(outcome.NextAttemptAt > Scenario.Start);
        Assert.Null(outcome.ProcessedAt);
    }

    [Fact]
    public async Task Entry_no_longer_held_is_not_sent_and_nothing_is_written()
    {
        _s.Invoices.Add(Number, InvoiceStatus.Pending, sendAttempts: 1);
        _s.Outbox.Held = false;

        await Send(Entry(1));

        Assert.Empty(_s.Erp.Calls);
        Assert.Empty(_s.Outbox.Outcomes);
        Assert.Equal(0, _s.UnitOfWork.Begun);
    }

    [Fact]
    public async Task Last_failed_attempt_asks_the_ERP_once_more_before_giving_up()
    {
        _s.Invoices.Add(Number, InvoiceStatus.Pending, sendAttempts: 3);
        _s.Erp.LookupResults.Enqueue(FakeErpGateway.NotFound());
        _s.Erp.SendResults.Enqueue(FakeErpGateway.ServerError());
        // The 500 came after the ERP saved it.
        _s.Erp.LookupResults.Enqueue(FakeErpGateway.Found("ERP-9"));

        await Send(Entry(_s.OutboxSettings.MaxAttempts));

        Assert.Equal(["GET " + Number, "POST " + Number, "GET " + Number], _s.Erp.Calls);
        Assert.Equal(InvoiceStatus.Sent, _s.Invoices.Invoices[Number].Status);
        Assert.Equal("ERP-9", _s.Invoices.Invoices[Number].ErpReference);
    }

    [Fact]
    public async Task Last_failed_attempt_the_ERP_does_not_have_fails_the_invoice()
    {
        _s.Invoices.Add(Number, InvoiceStatus.Pending, sendAttempts: 3);
        _s.Erp.LookupResults.Enqueue(FakeErpGateway.NotFound());
        _s.Erp.SendResults.Enqueue(FakeErpGateway.ServerError());
        _s.Erp.LookupResults.Enqueue(FakeErpGateway.NotFound());

        await Send(Entry(_s.OutboxSettings.MaxAttempts));

        Assert.Equal(InvoiceStatus.Failed, _s.Invoices.Invoices[Number].Status);
        Assert.Equal("ERP 500", _s.Invoices.Invoices[Number].LastError);
        Assert.Equal(OutboxStatus.Failed, Assert.Single(_s.Outbox.Outcomes).Status);
    }

    [Fact]
    public async Task Cut_off_last_attempt_is_not_sent_again_the_ERP_is_only_asked()
    {
        _s.Invoices.Add(Number, InvoiceStatus.Pending, sendAttempts: 3);
        _s.Erp.LookupResults.Enqueue(FakeErpGateway.NotFound());

        await Send(Entry(_s.OutboxSettings.MaxAttempts, usedUp: true));

        Assert.Equal(["GET " + Number], _s.Erp.Calls);
        Assert.Equal(InvoiceStatus.Failed, _s.Invoices.Invoices[Number].Status);
        Assert.Equal("Son deneme yarıda kaldı (servis durdu).", _s.Invoices.Invoices[Number].LastError);
    }

    [Fact]
    public async Task Outcome_of_an_entry_taken_again_meanwhile_is_dropped()
    {
        _s.Invoices.Add(Number, InvoiceStatus.Pending, sendAttempts: 1);
        _s.Erp.SendResults.Enqueue(FakeErpGateway.Accepted("ERP-1"));
        _s.Outbox.Owned = false;

        await Send(Entry(1));

        Assert.Equal(InvoiceStatus.Pending, _s.Invoices.Invoices[Number].Status);
        Assert.Null(_s.Invoices.Invoices[Number].ErpReference);
        Assert.Equal(0, _s.UnitOfWork.Committed);
    }

    [Fact]
    public async Task Events_that_waited_for_the_invoice_are_applied_when_it_becomes_sent()
    {
        _s.Invoices.Add(Number, InvoiceStatus.Pending, sendAttempts: 1);
        // The decision arrived before the invoice was sent: it waits.
        await _s.WebhookEventProcessor().ReceiveAsync(
            new ErpWebhookRequest("e-1", WebhookEventType.Approved, Number, "ERP-1", Scenario.Start, null), "{}", default);
        Assert.Equal(WebhookEventStatus.Pending, _s.Events.Events["e-1"].Status);
        _s.Erp.SendResults.Enqueue(FakeErpGateway.Accepted("ERP-1"));

        await Send(Entry(1));

        Assert.Equal(InvoiceStatus.Approved, _s.Invoices.Invoices[Number].Status);
        Assert.Equal(WebhookEventStatus.Processed, _s.Events.Events["e-1"].Status);
        Assert.Equal(Scenario.Start, _s.Events.Events["e-1"].ProcessedAt);
    }
}
