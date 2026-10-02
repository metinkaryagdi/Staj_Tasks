using InvoiceService.Data;
using InvoiceService.Webhooks;

namespace InvoiceService.Tests;

public class InvoiceTransitionsTests
{
    [Theory]
    [InlineData(InvoiceStatus.Sent, WebhookEventType.Received, InvoiceStatus.Processing)]
    [InlineData(InvoiceStatus.Sent, WebhookEventType.Approved, InvoiceStatus.Approved)]
    [InlineData(InvoiceStatus.Sent, WebhookEventType.Rejected, InvoiceStatus.Rejected)]
    [InlineData(InvoiceStatus.Processing, WebhookEventType.Approved, InvoiceStatus.Approved)]
    [InlineData(InvoiceStatus.Processing, WebhookEventType.Rejected, InvoiceStatus.Rejected)]
    public void Forward_events_are_applied(string status, string eventType, string expected)
    {
        Assert.Equal(new Transition(TransitionOutcome.Apply, expected), InvoiceTransitions.For(status, eventType));
    }

    [Theory]
    [InlineData(InvoiceStatus.Processing, WebhookEventType.Received, IgnoreReason.NotForward)]
    [InlineData(InvoiceStatus.Approved, WebhookEventType.Received, IgnoreReason.Backward)]
    [InlineData(InvoiceStatus.Rejected, WebhookEventType.Received, IgnoreReason.Backward)]
    [InlineData(InvoiceStatus.Approved, WebhookEventType.Approved, IgnoreReason.Final)]
    [InlineData(InvoiceStatus.Approved, WebhookEventType.Rejected, IgnoreReason.Final)]
    [InlineData(InvoiceStatus.Rejected, WebhookEventType.Approved, IgnoreReason.Final)]
    [InlineData(InvoiceStatus.Rejected, WebhookEventType.Rejected, IgnoreReason.Final)]
    public void Events_that_do_not_move_forward_are_ignored(string status, string eventType, string reason)
    {
        Assert.Equal(new Transition(TransitionOutcome.Ignore, IgnoreReason: reason), InvoiceTransitions.For(status, eventType));
    }

    [Theory]
    [InlineData(InvoiceStatus.Pending, WebhookEventType.Received)]
    [InlineData(InvoiceStatus.Pending, WebhookEventType.Approved)]
    [InlineData(InvoiceStatus.Failed, WebhookEventType.Received)]
    [InlineData(InvoiceStatus.Failed, WebhookEventType.Rejected)]
    public void Events_before_the_invoice_is_sent_wait(string status, string eventType)
    {
        Assert.Equal(new Transition(TransitionOutcome.Wait), InvoiceTransitions.For(status, eventType));
    }

    [Fact]
    public void Every_status_and_event_type_has_a_rule()
    {
        foreach (var status in InvoiceStatus.All)
            foreach (var eventType in WebhookEventType.All)
                InvoiceTransitions.For(status, eventType);
    }
}
