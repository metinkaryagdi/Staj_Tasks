using ErpSimulator.Application.Invoices;
using ErpSimulator.Application.Tests.Fakes;
using ErpSimulator.Domain.Invoices;
using ErpSimulator.Domain.Webhooks;

namespace ErpSimulator.Application.Tests;

/// <summary>The ERP's decision about an invoice, from the events planned for it.</summary>
public class InvoiceDecisionsTests
{
    private static readonly DateTimeOffset Saved = new(2026, 10, 5, 9, 0, 0, TimeSpan.Zero);

    private static WebhookDelivery Row(string type, int occurredAfterSeconds, string kind = DeliveryKind.Normal, string? reason = null) => new()
    {
        EventId = $"evt-{type}-{kind}", EventType = type, InvoiceNumber = "INV-1", InvoiceId = 1, Kind = kind,
        Payload = reason is null
            ? $$"""{"event_id":"e","event_type":"{{type}}","invoice_number":"INV-1","erp_reference":"ERP-1","occurred_at":"2026-10-05T09:00:00+00:00"}"""
            : $$"""{"event_id":"e","event_type":"{{type}}","invoice_number":"INV-1","erp_reference":"ERP-1","occurred_at":"2026-10-05T09:00:00+00:00","reason":"{{reason}}"}""",
        OccurredAt = Saved.AddSeconds(occurredAfterSeconds), DueAt = Saved, Status = DeliveryStatus.Pending
    };

    private static InvoiceDecision At(int secondsAfterSaved, params WebhookDelivery[] rows) =>
        InvoiceDecisions.Resolve(rows, Saved.AddSeconds(secondsAfterSaved));

    [Fact]
    public void No_events_planned_is_none()
    {
        Assert.Equal(DecisionKind.None, At(100).Kind);
    }

    [Fact]
    public void Before_the_first_event_is_none()
    {
        var decision = At(1, Row(ErpEventType.Received, 5), Row(ErpEventType.Approved, 10));

        Assert.Equal(DecisionKind.None, decision.Kind);
    }

    [Fact]
    public void After_received_but_before_the_decision_is_received()
    {
        var decision = At(7, Row(ErpEventType.Received, 5), Row(ErpEventType.Approved, 10));

        Assert.Equal(DecisionKind.Received, decision.Kind);
        Assert.Null(decision.DecidedAt);
    }

    [Fact]
    public void After_the_decision_time_it_is_approved_with_the_time_it_was_made()
    {
        var decision = At(11, Row(ErpEventType.Received, 5), Row(ErpEventType.Approved, 10));

        Assert.Equal(DecisionKind.Approved, decision.Kind);
        Assert.Equal(Saved.AddSeconds(10), decision.DecidedAt);
        Assert.Null(decision.Reason);
    }

    [Fact]
    public void Rejected_carries_the_reason_from_the_event()
    {
        var decision = At(11, Row(ErpEventType.Received, 5), Row(ErpEventType.Rejected, 10, reason: "Müşteri kaydı bulunamadı"));

        Assert.Equal(DecisionKind.Rejected, decision.Kind);
        Assert.Equal("Müşteri kaydı bulunamadı", decision.Reason);
    }

    [Fact]
    public void A_decision_whose_event_was_never_sent_still_counts_once_its_time_has_come()
    {
        var lost = Row(ErpEventType.Approved, 10, DeliveryKind.LostDecision);
        lost.Status = DeliveryStatus.Skipped;

        Assert.Equal(DecisionKind.Received, At(8, Row(ErpEventType.Received, 5), lost).Kind);
        Assert.Equal(DecisionKind.Approved, At(11, Row(ErpEventType.Received, 5), lost).Kind);
    }

    [Fact]
    public void Fake_replayed_and_duplicated_events_are_not_decisions()
    {
        var decision = At(
            100,
            Row(ErpEventType.Received, 5),
            Row(ErpEventType.Approved, 10, DeliveryKind.Fake),
            Row(ErpEventType.Rejected, 10, DeliveryKind.Replay, "x"),
            Row(ErpEventType.Rejected, 10, DeliveryKind.Duplicate, "x"));

        Assert.Equal(DecisionKind.Received, decision.Kind);
    }

    [Fact]
    public void The_order_the_events_were_sent_in_does_not_matter()
    {
        // Order mix: the decision happened before the received event was delivered; only the sending is swapped.
        var decision = At(11, Row(ErpEventType.Approved, 10), Row(ErpEventType.Received, 4));

        Assert.Equal(DecisionKind.Approved, decision.Kind);
    }
}

/// <summary>Looking an invoice number up: its records and the first record's decision.</summary>
public class InvoiceLookupTests
{
    private static readonly DateTimeOffset Now = new(2026, 10, 5, 9, 0, 30, TimeSpan.Zero);

    private static ErpInvoice Record(string number) => new()
    {
        InvoiceNumber = number, CustomerCode = "C-001", Currency = "TRY", Behavior = "Success"
    };

    [Fact]
    public async Task An_unknown_invoice_number_has_no_records_and_no_decision()
    {
        var lookup = new InvoiceLookup(new FakeErpInvoiceStore(), new FakeDeliveryStore(), new FixedTime(Now));

        var found = await lookup.FindAsync("INV-9", CancellationToken.None);

        Assert.Empty(found.Records);
        Assert.Equal(DecisionKind.None, found.Decision.Kind);
    }

    [Fact]
    public async Task The_decision_is_the_first_records_when_the_number_has_duplicates()
    {
        var invoices = new FakeErpInvoiceStore();
        await invoices.SaveAsync(Record("INV-1"), _ => []);
        await invoices.SaveAsync(Record("INV-1"), _ => []);
        var deliveries = new FakeDeliveryStore();
        deliveries.Planned.Add(new WebhookDelivery
        {
            EventId = "e1", EventType = ErpEventType.Approved, InvoiceId = invoices.Records[1].Id, InvoiceNumber = "INV-1",
            Kind = DeliveryKind.Normal, Payload = "{}", OccurredAt = Now.AddSeconds(-5), Status = DeliveryStatus.Delivered
        });
        var lookup = new InvoiceLookup(invoices, deliveries, new FixedTime(Now));

        var found = await lookup.FindAsync("INV-1", CancellationToken.None);

        Assert.Equal(2, found.Records.Count);
        Assert.Equal(DecisionKind.None, found.Decision.Kind);
    }

    [Fact]
    public async Task A_decision_whose_time_has_come_is_returned_with_the_records()
    {
        var invoices = new FakeErpInvoiceStore();
        await invoices.SaveAsync(Record("INV-1"), _ => []);
        var deliveries = new FakeDeliveryStore();
        deliveries.Planned.Add(new WebhookDelivery
        {
            EventId = "e1", EventType = ErpEventType.Approved, InvoiceId = invoices.Records[0].Id, InvoiceNumber = "INV-1",
            Kind = DeliveryKind.LostDecision, Payload = "{}", OccurredAt = Now.AddSeconds(-5), Status = DeliveryStatus.Skipped
        });
        var lookup = new InvoiceLookup(invoices, deliveries, new FixedTime(Now));

        var found = await lookup.FindAsync("INV-1", CancellationToken.None);

        Assert.Equal(DecisionKind.Approved, found.Decision.Kind);
        Assert.Equal(Now.AddSeconds(-5), found.Decision.DecidedAt);
    }
}
