using InvoiceService.Application.Tests.Fakes;
using InvoiceService.Application.Webhooks;
using InvoiceService.Domain.Invoices;
using InvoiceService.Domain.Webhooks;

namespace InvoiceService.Application.Tests;

public class WebhookEventProcessorTests
{
    private const string Number = "FTR-000001";
    private readonly Scenario _s = new();

    private Task<EventResult> Receive(string id, string type, string reference = "ERP-1", string? reason = null, string payload = "{}") =>
        _s.WebhookEventProcessor().ReceiveAsync(
            new ErpWebhookRequest(id, type, Number, reference, Scenario.Start, reason), payload, default);

    [Fact]
    public async Task Event_for_a_sent_invoice_is_applied()
    {
        _s.Invoices.Add(Number, InvoiceStatus.Sent, erpReference: "ERP-1");

        var result = await Receive("e-1", WebhookEventType.Received);

        Assert.Equal(new EventResult("e-1", WebhookEventStatus.Processed, false), result);
        Assert.Equal(InvoiceStatus.Processing, _s.Invoices.Invoices[Number].Status);
        Assert.Equal(1, _s.UnitOfWork.Committed);
    }

    [Fact]
    public async Task Repeated_event_is_counted_but_not_applied_again()
    {
        _s.Invoices.Add(Number, InvoiceStatus.Sent, erpReference: "ERP-1");
        await Receive("e-1", WebhookEventType.Approved);
        _s.Invoices.Invoices[Number].Status = InvoiceStatus.Sent; // would be visible if it were applied again

        var result = await Receive("e-1", WebhookEventType.Approved);

        Assert.True(result.Repeat);
        Assert.Equal(2, _s.Events.Events["e-1"].DeliveryCount);
        Assert.Equal(InvoiceStatus.Sent, _s.Invoices.Invoices[Number].Status);
    }

    [Fact]
    public async Task The_cancellation_of_a_failed_invoice_waits_when_it_is_not_the_services_own()
    {
        var invoice = _s.Invoices.Add(Number, InvoiceStatus.Failed);
        invoice.LastError = "ERP'de bu numara farklı içerikle kayıtlı (ERP-9): tutar: serviste 10.50, ERP'de 99.00.";

        var result = await Receive("e-1", WebhookEventType.Cancelled, reference: "ERP-9");

        Assert.Equal(WebhookEventStatus.Pending, result.Status);
        Assert.Equal(InvoiceStatus.Failed, invoice.Status);
        Assert.Null(invoice.ErpReference);
        Assert.Contains("farklı içerikle kayıtlı", invoice.LastError);
    }

    [Fact]
    public async Task The_cancellation_of_a_failed_invoice_is_applied_when_the_service_cancelled_it()
    {
        _s.Invoices.Add(Number, InvoiceStatus.Failed);
        _s.Outbox.CancelEntries[Number] = new Domain.Outbox.ErpOutboxEntry
        {
            InvoiceNumber = Number, Kind = Domain.Outbox.OutboxKind.Cancel, Status = Domain.Outbox.OutboxStatus.Completed
        };

        var result = await Receive("e-1", WebhookEventType.Cancelled);

        Assert.Equal(WebhookEventStatus.Processed, result.Status);
        Assert.Equal(InvoiceStatus.Cancelled, _s.Invoices.Invoices[Number].Status);
    }

    [Fact]
    public async Task Event_for_an_invoice_not_known_here_waits()
    {
        var result = await Receive("e-1", WebhookEventType.Approved);

        Assert.Equal(WebhookEventStatus.Pending, result.Status);
        Assert.Equal(1, _s.UnitOfWork.Committed);
    }

    [Fact]
    public async Task Event_with_another_reference_is_ignored()
    {
        _s.Invoices.Add(Number, InvoiceStatus.Sent, erpReference: "ERP-1");

        var result = await Receive("e-1", WebhookEventType.Approved, reference: "ERP-2");

        Assert.Equal(WebhookEventStatus.Ignored, result.Status);
        Assert.Equal(IgnoreReason.ReferenceMismatch, _s.Events.Events["e-1"].IgnoreReason);
        Assert.Equal(InvoiceStatus.Sent, _s.Invoices.Invoices[Number].Status);
    }

    [Fact]
    public async Task Rejection_keeps_the_reason_from_the_stored_body()
    {
        _s.Invoices.Add(Number, InvoiceStatus.Sent, erpReference: "ERP-1");

        await Receive("e-1", WebhookEventType.Rejected, reason: "Vergi no hatalı",
            payload: """{"event_id":"e-1","reason":"Vergi no hatalı"}""");

        Assert.Equal(InvoiceStatus.Rejected, _s.Invoices.Invoices[Number].Status);
        Assert.Equal("Vergi no hatalı", _s.Invoices.Invoices[Number].RejectReason);
    }
}
