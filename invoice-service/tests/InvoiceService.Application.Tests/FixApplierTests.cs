using InvoiceService.Application.Abstractions;
using InvoiceService.Application.Reconciliation;
using InvoiceService.Application.Tests.Fakes;
using InvoiceService.Domain.Invoices;
using InvoiceService.Domain.Reconciliation;
using InvoiceService.Domain.Webhooks;

namespace InvoiceService.Application.Tests;

/// <summary>Writing a reconciliation fix: only when the invoice is still what the plan saw, once the lock is
/// held.</summary>
public class FixApplierTests
{
    private const string Number = "FTR-000001";
    private readonly Scenario _s = new();

    private static ErpDecision Decided(string kind, string? reason = null) => new(kind, reason, Scenario.Start);

    private static Fix Decision(string expectedStatus, ErpDecision decision, string reference = "ERP-1") =>
        new(FixKind.ApplyDecision, Number, expectedStatus, reference, decision);

    private static Fix Recover(ErpDecision decision, string reference = "ERP-1") =>
        new(FixKind.RecoverFailed, Number, InvoiceStatus.Failed, reference, decision);

    private Invoice Invoice => _s.Invoices.Invoices[Number];

    private Task<bool> Apply(Fix fix, string type = FindingType.StuckInvoice) =>
        _s.FixApplier().ApplyAsync(7, new PlannedFinding(Number, type, "ayrıntı", fix));

    private ErpWebhookEvent AddWaitingEvent(string id, string type, string reference = "ERP-1")
    {
        var e = new ErpWebhookEvent
        {
            EventId = id, EventType = type, InvoiceNumber = Number, ErpReference = reference,
            ReceivedAt = Scenario.Start.AddMinutes(-5), Status = WebhookEventStatus.Pending, Payload = "{}"
        };
        _s.Events.Events[id] = e;
        return e;
    }

    // --- ApplyDecision
    // ------------------------------------------------------------------------------------------------

    [Fact]
    public async Task A_decision_moves_a_sent_invoice_in_one_transaction()
    {
        _s.Invoices.Add(Number, InvoiceStatus.Sent, erpReference: "ERP-1");

        var applied = await Apply(Decision(InvoiceStatus.Sent, Decided(ErpDecisionKind.Approved)));

        Assert.True(applied);
        Assert.Equal(InvoiceStatus.Approved, Invoice.Status);
        Assert.Equal(Scenario.Start, Invoice.UpdatedAt);
        Assert.Equal(1, _s.UnitOfWork.Committed);
    }

    [Fact]
    public async Task A_rejection_keeps_the_erps_reason_and_one_without_reason_gets_a_stated_placeholder()
    {
        _s.Invoices.Add(Number, InvoiceStatus.Processing, erpReference: "ERP-1");
        await Apply(Decision(InvoiceStatus.Processing, Decided(ErpDecisionKind.Rejected, "Mükerrer fatura")));
        Assert.Equal("Mükerrer fatura", Invoice.RejectReason);

        _s.Invoices.Add(Number, InvoiceStatus.Sent, erpReference: "ERP-1");
        await Apply(Decision(InvoiceStatus.Sent, Decided(ErpDecisionKind.Rejected)));
        Assert.Equal("ERP sebep bildirmedi", Invoice.RejectReason);
    }

    [Theory]
    [InlineData(InvoiceStatus.Approved)]
    [InlineData(InvoiceStatus.Rejected)]
    [InlineData(InvoiceStatus.Pending)]
    public async Task An_invoice_that_an_event_or_a_resend_changed_after_the_plan_is_left_alone(string newStatus)
    {
        _s.Invoices.Add(Number, newStatus, erpReference: "ERP-1");

        var applied = await Apply(Decision(InvoiceStatus.Sent, Decided(ErpDecisionKind.Approved)));

        Assert.False(applied);
        Assert.Equal(newStatus, Invoice.Status);
        Assert.Equal(0, _s.UnitOfWork.Committed);
    }

    [Fact]
    public async Task An_invoice_whose_reference_changed_or_that_is_gone_is_left_alone()
    {
        _s.Invoices.Add(Number, InvoiceStatus.Sent, erpReference: "ERP-2");
        var changed = await Apply(Decision(InvoiceStatus.Sent, Decided(ErpDecisionKind.Approved), reference: "ERP-1"));

        _s.Invoices.Invoices.Clear();
        var gone = await Apply(Decision(InvoiceStatus.Sent, Decided(ErpDecisionKind.Approved)));

        Assert.False(changed);
        Assert.False(gone);
        Assert.Equal(0, _s.UnitOfWork.Committed);
    }

    [Fact]
    public async Task A_decision_that_would_not_move_the_invoice_forward_is_not_written()
    {
        _s.Invoices.Add(Number, InvoiceStatus.Processing, erpReference: "ERP-1");

        var applied = await Apply(Decision(InvoiceStatus.Processing, Decided(ErpDecisionKind.Received)));

        Assert.False(applied);
        Assert.Equal(InvoiceStatus.Processing, Invoice.Status);
    }

    // --- RecoverFailed
    // ------------------------------------------------------------------------------------------------

    [Fact]
    public async Task A_failed_invoice_becomes_sent_with_the_erps_reference_and_its_outbox_entry_is_completed()
    {
        var invoice = _s.Invoices.Add(Number, InvoiceStatus.Failed);
        invoice.LastError = "10 deneme sonunda başarısız";

        var applied = await Apply(Recover(ErpDecision.None, "ERP-42"));

        Assert.True(applied);
        Assert.Equal(InvoiceStatus.Sent, invoice.Status);
        Assert.Equal("ERP-42", invoice.ErpReference);
        Assert.Null(invoice.LastError);
        Assert.Equal([Number], _s.Outbox.Completed);
        Assert.Equal(1, _s.UnitOfWork.Committed);
    }

    [Fact]
    public async Task A_recovered_invoice_also_takes_the_erps_decision()
    {
        _s.Invoices.Add(Number, InvoiceStatus.Failed);

        await Apply(Recover(Decided(ErpDecisionKind.Rejected, "Vergi numarası geçersiz")));

        Assert.Equal(InvoiceStatus.Rejected, Invoice.Status);
        Assert.Equal("Vergi numarası geçersiz", Invoice.RejectReason);
        Assert.Equal("ERP-1", Invoice.ErpReference);
    }

    [Fact]
    public async Task Events_that_waited_for_the_failed_invoice_are_applied_before_the_decision()
    {
        _s.Invoices.Add(Number, InvoiceStatus.Failed);
        var received = AddWaitingEvent("e-1", WebhookEventType.Received);
        var other = AddWaitingEvent("e-2", WebhookEventType.Approved, reference: "ERP-OTHER");

        await Apply(Recover(Decided(ErpDecisionKind.Approved)));

        Assert.Equal(WebhookEventStatus.Processed, received.Status);
        Assert.Equal(WebhookEventStatus.Ignored, other.Status);
        Assert.Equal(IgnoreReason.ReferenceMismatch, other.IgnoreReason);
        Assert.Equal(InvoiceStatus.Approved, Invoice.Status);
    }

    [Fact]
    public async Task A_decision_does_not_undo_a_waiting_event_that_already_finished_the_invoice()
    {
        _s.Invoices.Add(Number, InvoiceStatus.Failed);
        AddWaitingEvent("e-1", WebhookEventType.Rejected);

        await Apply(Recover(Decided(ErpDecisionKind.Approved)));

        // Onaylandı and Reddedildi are final: the rejection that was waiting came first, the approval changes nothing.
        Assert.Equal(InvoiceStatus.Rejected, Invoice.Status);
    }

    [Theory]
    [InlineData(InvoiceStatus.Pending)]
    [InlineData(InvoiceStatus.Sent)]
    [InlineData(InvoiceStatus.Approved)]
    public async Task An_invoice_that_is_no_longer_failed_is_not_recovered(string status)
    {
        _s.Invoices.Add(Number, status);

        var applied = await Apply(Recover(Decided(ErpDecisionKind.Approved)));

        Assert.False(applied);
        Assert.Equal(status, Invoice.Status);
        Assert.Empty(_s.Outbox.Completed);
        Assert.Equal(0, _s.UnitOfWork.Committed);
    }

    // --- IgnoreEvent
    // --------------------------------------------------------------------------------------------------

    [Fact]
    public async Task A_waiting_event_for_an_unknown_invoice_becomes_ignored()
    {
        var e = AddWaitingEvent("e-1", WebhookEventType.Received);

        var applied = await Apply(new Fix(FixKind.IgnoreEvent, Number, EventId: "e-1"));

        Assert.True(applied);
        Assert.Equal(WebhookEventStatus.Ignored, e.Status);
        Assert.Equal(IgnoreReason.UnknownInvoice, e.IgnoreReason);
    }

    [Fact]
    public async Task An_event_that_was_already_handled_or_whose_invoice_has_arrived_is_left_alone()
    {
        var handled = AddWaitingEvent("e-1", WebhookEventType.Received);
        handled.Status = WebhookEventStatus.Processed;
        var arrived = AddWaitingEvent("e-2", WebhookEventType.Approved);
        _s.Events.KnownInvoices.Add(Number);

        var first = await Apply(new Fix(FixKind.IgnoreEvent, Number, EventId: "e-1"));
        var second = await Apply(new Fix(FixKind.IgnoreEvent, Number, EventId: "e-2"));

        Assert.False(first);
        Assert.False(second);
        Assert.Equal(WebhookEventStatus.Pending, arrived.Status);
    }
}
