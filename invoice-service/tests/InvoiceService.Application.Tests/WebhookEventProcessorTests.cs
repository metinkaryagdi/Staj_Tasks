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
