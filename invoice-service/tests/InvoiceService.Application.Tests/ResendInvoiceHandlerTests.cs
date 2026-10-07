using InvoiceService.Application.Invoices;
using InvoiceService.Application.Tests.Fakes;
using InvoiceService.Domain.Invoices;
using InvoiceService.Domain.Operators;

namespace InvoiceService.Application.Tests;

public class ResendInvoiceHandlerTests
{
    private readonly Scenario _s = new();

    [Fact]
    public async Task Failed_invoice_is_queued_again_with_a_fresh_outbox_entry()
    {
        _s.Invoices.Add("FTR-000001", InvoiceStatus.Failed).LastError = "ERP 500";

        var result = await _s.ResendInvoiceHandler().HandleAsync("FTR-000001", "Ayşe");

        Assert.Equal(ResendStatus.Queued, result.Status);
        Assert.Equal(InvoiceStatus.Pending, result.Invoice!.Status);
        Assert.Null(result.Invoice.LastError);
        Assert.Equal(["FTR-000001"], _s.Outbox.Resets);
        Assert.Equal(1, _s.UnitOfWork.Committed);
        AssertRecorded("FTR-000001", OperatorActionResult.Queued);
    }

    [Fact]
    public async Task Invoice_that_is_not_failed_is_refused_and_nothing_is_reset()
    {
        _s.Invoices.Add("FTR-000001", InvoiceStatus.Sent);

        var result = await _s.ResendInvoiceHandler().HandleAsync("FTR-000001", "Ayşe");

        Assert.Equal(ResendStatus.NotFailed, result.Status);
        Assert.Equal(InvoiceStatus.Sent, result.CurrentStatus);
        Assert.Empty(_s.Outbox.Resets);
        // Only the record of the refused request is committed.
        Assert.Equal(1, _s.UnitOfWork.Committed);
        AssertRecorded("FTR-000001", "Reddedildi: fatura Gönderildi");
    }

    [Fact]
    public async Task Unknown_invoice_is_not_found()
    {
        var result = await _s.ResendInvoiceHandler().HandleAsync("FTR-999999", "Ayşe");

        Assert.Equal(ResendStatus.NotFound, result.Status);
        Assert.Empty(_s.Outbox.Resets);
        AssertRecorded("FTR-999999", OperatorActionResult.NotFound);
    }

    [Fact]
    public async Task A_number_too_long_for_an_invoice_is_recorded_cut_to_the_column()
    {
        var number = new string('9', 80);

        await _s.ResendInvoiceHandler().HandleAsync(number, "Ayşe");

        Assert.Equal(number[..OperatorAction.MaxInvoiceNumberLength], Assert.Single(_s.OperatorActions.Actions).InvoiceNumber);
    }

    private void AssertRecorded(string invoiceNumber, string result)
    {
        var action = Assert.Single(_s.OperatorActions.Actions);
        Assert.Equal(("Ayşe", OperatorActionType.Resend, invoiceNumber, result),
            (action.OperatorName, action.Action, action.InvoiceNumber, action.Result));
    }

    [Fact]
    public async Task Invalid_request_is_not_queued()
    {
        var result = await _s.CreateInvoiceHandler().HandleAsync(new CreateInvoiceRequest("", 1.234m, "try", null));

        Assert.Null(result.Invoice);
        Assert.Equal(["CustomerCode", "Amount", "Currency", "InvoiceDate"], result.Errors!.Keys);
        Assert.Empty(_s.Invoices.Queued);
    }

    [Fact]
    public async Task Valid_request_queues_the_invoice_and_its_outbox_entry_together()
    {
        var result = await _s.CreateInvoiceHandler().HandleAsync(
            new CreateInvoiceRequest("C-001", 10.50m, "TRY", new DateOnly(2026, 10, 1)));

        var (invoice, entry) = Assert.Single(_s.Invoices.Queued);
        Assert.Same(invoice, result.Invoice);
        Assert.Equal("FTR-000001", invoice.InvoiceNumber);
        Assert.Equal(InvoiceStatus.Pending, invoice.Status);
        Assert.Equal(invoice.InvoiceNumber, entry.InvoiceNumber);
        Assert.Equal(0, entry.AttemptCount);
        Assert.Equal(Scenario.Start, entry.NextAttemptAt);
    }
}
