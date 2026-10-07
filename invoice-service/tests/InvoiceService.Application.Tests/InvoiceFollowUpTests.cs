using InvoiceService.Application.Tests.Fakes;
using InvoiceService.Application.Invoices;
using InvoiceService.Domain.Invoices;
using InvoiceService.Domain.Operators;

namespace InvoiceService.Application.Tests;

public class InvoiceFollowUpTests
{
    private readonly Scenario _s = new();

    [Fact]
    public async Task Opens_follow_up_for_stuck_invoice_and_records_action_in_same_transaction()
    {
        _s.Invoices.Add("FTR-000001", InvoiceStatus.Sent).UpdatedAt = Scenario.Start.AddMinutes(-3);

        var result = await _s.InvoiceFollowUpHandler().OpenAsync("FTR-000001", "Ayşe", "ERP yanıtı bekleniyor", CancellationToken.None);

        Assert.Equal(FollowUpStatus.Opened, result.Status);
        Assert.Equal("Ayşe", result.FollowUp!.OperatorName);
        Assert.Equal(OperatorActionType.FollowUp, _s.OperatorActions.Actions.Single().Action);
        Assert.Equal(OperatorActionResult.FollowUpOpened, _s.OperatorActions.Actions.Single().Result);
        Assert.Equal(1, _s.UnitOfWork.Committed);
    }

    [Fact]
    public async Task Refuses_non_stuck_invoice_and_records_refusal()
    {
        _s.Invoices.Add("FTR-000001", InvoiceStatus.Approved);

        var result = await _s.InvoiceFollowUpHandler().OpenAsync("FTR-000001", "Ayşe", "Not", CancellationToken.None);

        Assert.Equal(FollowUpStatus.NotStuck, result.Status);
        Assert.Empty(_s.FollowUps.FollowUps);
        Assert.Equal("Reddedildi: fatura takılı değil (Onaylandı)", _s.OperatorActions.Actions.Single().Result);
    }

    [Fact]
    public async Task Refuses_duplicate_open_follow_up_then_allows_reopen_after_close()
    {
        _s.Invoices.Add("FTR-000001", InvoiceStatus.Sent).UpdatedAt = Scenario.Start.AddMinutes(-3);
        var handler = _s.InvoiceFollowUpHandler();
        Assert.Equal(FollowUpStatus.Opened, (await handler.OpenAsync("FTR-000001", "Ayşe", "İlk", CancellationToken.None)).Status);
        Assert.Equal(FollowUpStatus.AlreadyOpen, (await handler.OpenAsync("FTR-000001", "Mehmet", "İkinci", CancellationToken.None)).Status);
        Assert.Equal(FollowUpStatus.Closed, (await handler.CloseAsync("FTR-000001", "Mehmet", CancellationToken.None)).Status);
        Assert.Equal(FollowUpStatus.Opened, (await handler.OpenAsync("FTR-000001", "Mehmet", "Yeniden", CancellationToken.None)).Status);
        Assert.Equal(2, _s.FollowUps.FollowUps.Count);
    }

    [Fact]
    public async Task Missing_invoice_and_close_without_open_follow_up_are_refused()
    {
        var handler = _s.InvoiceFollowUpHandler();
        Assert.Equal(FollowUpStatus.InvoiceNotFound, (await handler.OpenAsync("FTR-999999", "Ayşe", "Not", CancellationToken.None)).Status);
        Assert.Equal(FollowUpStatus.NotOpen, (await handler.CloseAsync("FTR-999999", "Ayşe", CancellationToken.None)).Status);
        Assert.Equal(2, _s.OperatorActions.Actions.Count);
        Assert.All(_s.OperatorActions.Actions, action => Assert.Equal("FTR-999999", action.InvoiceNumber));
    }

    [Fact]
    public async Task Invalid_note_is_refused_and_recorded_without_creating_follow_up()
    {
        _s.Invoices.Add("FTR-000001", InvoiceStatus.Sent).UpdatedAt = Scenario.Start.AddMinutes(-3);

        var result = await _s.InvoiceFollowUpHandler().OpenAsync("FTR-000001", "Ayşe", "   ", CancellationToken.None);

        Assert.Equal(FollowUpStatus.InvalidNote, result.Status);
        Assert.Empty(_s.FollowUps.FollowUps);
        Assert.Equal(OperatorActionResult.InvalidNote, _s.OperatorActions.Actions.Single().Result);
    }

    [Fact]
    public async Task Duplicate_refusal_fits_operator_action_result_limit_for_a_long_name()
    {
        _s.Invoices.Add("FTR-000001", InvoiceStatus.Sent).UpdatedAt = Scenario.Start.AddMinutes(-3);
        var handler = _s.InvoiceFollowUpHandler();
        await handler.OpenAsync("FTR-000001", new string('a', 100), "İlk", CancellationToken.None);

        var result = await handler.OpenAsync("FTR-000001", "Ayşe", "İkinci", CancellationToken.None);

        Assert.Equal(FollowUpStatus.AlreadyOpen, result.Status);
        Assert.True(_s.OperatorActions.Actions.Last().Result.Length <= OperatorAction.MaxResultLength);
    }

    [Fact]
    public async Task Follow_up_does_not_change_stuck_count_filter_or_flag_and_is_returned_by_reads()
    {
        var invoice = _s.Invoices.Add("FTR-000001", InvoiceStatus.Sent);
        invoice.UpdatedAt = Scenario.Start.AddMinutes(-3);
        await _s.InvoiceFollowUpHandler().OpenAsync(invoice.InvoiceNumber, "Ayşe", "Not", CancellationToken.None);
        var queries = _s.InvoiceQueries();

        Assert.Equal(1, (await queries.SummaryAsync(CancellationToken.None)).StuckCount);
        var list = await queries.ListAsync(null, null, true, 1, 20, CancellationToken.None);
        Assert.Single(list.Items);
        Assert.True(list.Items[0].Stuck);
        Assert.Equal("Ayşe", list.Items[0].FollowedBy);
        var details = await queries.DetailsAsync(invoice.InvoiceNumber, CancellationToken.None);
        Assert.True(details!.Stuck);
        Assert.Equal("Ayşe", details.FollowUp!.OperatorName);
        Assert.Single(details.FollowUps);
    }
}
