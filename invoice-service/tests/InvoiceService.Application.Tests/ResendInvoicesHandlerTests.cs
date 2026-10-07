using InvoiceService.Application.Invoices;
using InvoiceService.Application.Tests.Fakes;
using InvoiceService.Domain.Invoices;
using InvoiceService.Domain.Operators;

namespace InvoiceService.Application.Tests;

public class ResendInvoicesHandlerTests
{
    private readonly Scenario _s = new();

    private Task<BulkResendResult> Resend(params string[] numbers) =>
        _s.ResendInvoicesHandler().HandleAsync(new ResendInvoicesRequest(numbers), "Ayşe");

    [Fact]
    public async Task Every_invoice_gets_its_own_result_and_only_the_failed_one_is_queued()
    {
        _s.Invoices.Add("FTR-000001", InvoiceStatus.Failed);
        _s.Invoices.Add("FTR-000002", InvoiceStatus.Pending);
        _s.Invoices.Add("FTR-000003", InvoiceStatus.Approved);

        var result = await Resend("FTR-000001", "FTR-000002", "FTR-000003", "FTR-999999");

        Assert.Null(result.Errors);
        Assert.Equal(
            [
                new BulkResendItem("FTR-000001", BulkResendOutcome.Queued),
                new BulkResendItem("FTR-000002", BulkResendOutcome.NotFailed, InvoiceStatus.Pending),
                new BulkResendItem("FTR-000003", BulkResendOutcome.NotFailed, InvoiceStatus.Approved),
                new BulkResendItem("FTR-999999", BulkResendOutcome.NotFound)
            ],
            result.Items);
        Assert.Equal(["FTR-000001"], _s.Outbox.Resets);
        Assert.Equal(InvoiceStatus.Pending, _s.Invoices.Invoices["FTR-000001"].Status);
        Assert.Equal(
            [
                ("FTR-000001", OperatorActionResult.Queued),
                ("FTR-000002", "Reddedildi: fatura Bekliyor"),
                ("FTR-000003", "Reddedildi: fatura Onaylandı"),
                ("FTR-999999", OperatorActionResult.NotFound)
            ],
            _s.OperatorActions.Actions.Select(a => (a.InvoiceNumber!, a.Result)));
        Assert.All(_s.OperatorActions.Actions, a => Assert.Equal(("Ayşe", OperatorActionType.BulkResend), (a.OperatorName, a.Action)));
    }

    [Fact]
    public async Task A_number_sent_twice_is_resent_once_and_not_refused_as_already_queued()
    {
        _s.Invoices.Add("FTR-000001", InvoiceStatus.Failed);

        var result = await Resend("FTR-000001", " FTR-000001 ");

        Assert.Equal([new BulkResendItem("FTR-000001", BulkResendOutcome.Queued)], result.Items);
        Assert.Equal(["FTR-000001"], _s.Outbox.Resets);
    }

    [Fact]
    public async Task An_invoice_that_cannot_be_resent_is_reported_and_the_others_still_are()
    {
        _s.Invoices.Add("FTR-000001", InvoiceStatus.Failed);
        _s.Invoices.Add("FTR-000002", InvoiceStatus.Failed);
        _s.Invoices.Add("FTR-000003", InvoiceStatus.Failed);
        _s.Invoices.FailResend.Add("FTR-000002");

        var result = await Resend("FTR-000001", "FTR-000002", "FTR-000003");

        Assert.Equal(
            [BulkResendOutcome.Queued, BulkResendOutcome.Error, BulkResendOutcome.Queued],
            result.Items.Select(i => i.Outcome));
        Assert.Equal(["FTR-000001", "FTR-000003"], _s.Outbox.Resets);
        Assert.Equal(
            [("FTR-000001", OperatorActionResult.Queued), ("FTR-000002", OperatorActionResult.Error), ("FTR-000003", OperatorActionResult.Queued)],
            _s.OperatorActions.Actions.Select(a => (a.InvoiceNumber!, a.Result)));
    }

    [Fact]
    public async Task An_error_that_cannot_be_recorded_does_not_stop_the_other_invoices()
    {
        _s.Invoices.Add("FTR-000001", InvoiceStatus.Failed);
        _s.Invoices.Add("FTR-000002", InvoiceStatus.Failed);
        _s.Invoices.FailResend.Add("FTR-000001");
        _s.OperatorActions.Refuse.Add("FTR-000001");

        var result = await Resend("FTR-000001", "FTR-000002");

        Assert.Equal([BulkResendOutcome.Error, BulkResendOutcome.Queued], result.Items.Select(i => i.Outcome));
        Assert.Equal(["FTR-000002"], _s.OperatorActions.Actions.Select(a => a.InvoiceNumber));
    }

    [Fact]
    public async Task One_hundred_numbers_are_accepted_and_one_hundred_and_one_are_refused_before_anything_is_resent()
    {
        var hundred = Enumerable.Range(1, 100).Select(i => $"FTR-{i:D6}").ToArray();
        foreach (var number in hundred)
            _s.Invoices.Add(number, InvoiceStatus.Failed);

        var accepted = await Resend(hundred);
        Assert.Null(accepted.Errors);
        Assert.Equal(100, accepted.Items.Count(i => i.Outcome == BulkResendOutcome.Queued));

        var refused = await Resend([.. hundred, "FTR-000101"]);
        Assert.NotNull(refused.Errors);
        Assert.Empty(refused.Items);
        Assert.Equal(100, _s.Outbox.Resets.Count);
    }

    [Fact]
    public async Task An_empty_list_or_an_empty_number_is_refused()
    {
        _s.Invoices.Add("FTR-000001", InvoiceStatus.Failed);

        Assert.NotNull((await Resend()).Errors);
        Assert.NotNull((await Resend("FTR-000001", " ")).Errors);
        Assert.NotNull((await _s.ResendInvoicesHandler().HandleAsync(new ResendInvoicesRequest(null), "Ayşe")).Errors);
        Assert.Empty(_s.Outbox.Resets);
        Assert.Empty(_s.OperatorActions.Actions);
    }
}
