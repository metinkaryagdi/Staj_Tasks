using InvoiceService.Application.Tests.Fakes;
using InvoiceService.Domain.Invoices;
using InvoiceService.Domain.Outbox;
using InvoiceService.Domain.Reconciliation;
using InvoiceService.Domain.Webhooks;

namespace InvoiceService.Application.Tests;

public class InvoiceQueriesTests
{
    private readonly Scenario _s = new();

    [Fact]
    public async Task Summary_lists_every_status_with_zero_for_an_empty_one()
    {
        _s.Invoices.Add("FTR-000001", InvoiceStatus.Failed);
        _s.Invoices.Add("FTR-000002", InvoiceStatus.Failed);
        _s.Invoices.Add("FTR-000003", InvoiceStatus.Approved);

        var summary = await _s.InvoiceQueries().SummaryAsync(CancellationToken.None);

        Assert.Equal(InvoiceStatus.All, summary.Counts.Select(c => c.Status));
        Assert.Equal(2, summary.Counts.Single(c => c.Status == InvoiceStatus.Failed).Count);
        Assert.Equal(0, summary.Counts.Single(c => c.Status == InvoiceStatus.Pending).Count);
        Assert.Equal(3, summary.Total);
    }

    [Fact]
    public async Task Summary_counts_as_stuck_only_Sent_or_Processing_waiting_longer_than_the_reconciliation_limit()
    {
        // StuckAfterMinutes is 2 in the scenario.
        _s.Invoices.Add("FTR-000001", InvoiceStatus.Sent).UpdatedAt = Scenario.Start.AddMinutes(-3);
        _s.Invoices.Add("FTR-000002", InvoiceStatus.Processing).UpdatedAt = Scenario.Start.AddMinutes(-3);
        _s.Invoices.Add("FTR-000003", InvoiceStatus.Sent).UpdatedAt = Scenario.Start.AddMinutes(-1);
        _s.Invoices.Add("FTR-000004", InvoiceStatus.Failed).UpdatedAt = Scenario.Start.AddMinutes(-30);
        _s.Invoices.Add("FTR-000005", InvoiceStatus.Pending).UpdatedAt = Scenario.Start.AddMinutes(-30);
        _s.Invoices.Add("FTR-000006", InvoiceStatus.Approved).UpdatedAt = Scenario.Start.AddMinutes(-30);

        var summary = await _s.InvoiceQueries().SummaryAsync(CancellationToken.None);

        Assert.Equal(2, summary.StuckCount);
        Assert.Equal(2, summary.StuckAfterMinutes);
    }

    [Fact]
    public async Task List_pages_newest_first_and_reports_the_total_of_the_filtered_list()
    {
        for (var i = 1; i <= 5; i++)
            _s.Invoices.Add($"FTR-00000{i}", InvoiceStatus.Sent).CreatedAt = Scenario.Start.AddMinutes(i);

        var second = await _s.InvoiceQueries().ListAsync(null, null, false, page: 2, pageSize: 2, CancellationToken.None);

        Assert.Equal(["FTR-000003", "FTR-000002"], second.Items.Select(i => i.InvoiceNumber));
        Assert.Equal(5, second.TotalCount);
    }

    [Fact]
    public async Task List_filters_by_status_and_by_part_of_the_number_in_any_case()
    {
        _s.Invoices.Add("FTR-000001", InvoiceStatus.Failed);
        _s.Invoices.Add("FTR-000012", InvoiceStatus.Failed);
        _s.Invoices.Add("FTR-000013", InvoiceStatus.Sent);

        var result = await _s.InvoiceQueries().ListAsync(InvoiceStatus.Failed, " ftr-0000 ", false, 1, 20, CancellationToken.None);
        Assert.Equal(2, result.TotalCount);

        var narrowed = await _s.InvoiceQueries().ListAsync(InvoiceStatus.Failed, "12", false, 1, 20, CancellationToken.None);
        Assert.Equal(["FTR-000012"], narrowed.Items.Select(i => i.InvoiceNumber));
    }

    [Fact]
    public async Task Details_show_only_the_newest_ERP_Karar_Vermedi_finding_and_every_other_finding()
    {
        _s.Invoices.Add("FTR-000001", InvoiceStatus.Processing);
        _s.Reconciliation.Findings.AddRange(
        [
            new ReconciliationFinding { Id = 1, RunId = 1, InvoiceNumber = "FTR-000001", FindingType = FindingType.NoErpDecision,
                Action = FindingAction.Reported, Details = "ilk", CreatedAt = Scenario.Start.AddMinutes(-20) },
            new ReconciliationFinding { Id = 2, RunId = 2, InvoiceNumber = "FTR-000001", FindingType = FindingType.StuckInvoice,
                Action = FindingAction.Fixed, Details = "düzeltme", CreatedAt = Scenario.Start.AddMinutes(-15) },
            new ReconciliationFinding { Id = 3, RunId = 3, InvoiceNumber = "FTR-000001", FindingType = FindingType.NoErpDecision,
                Action = FindingAction.Reported, Details = "son", CreatedAt = Scenario.Start.AddMinutes(-10) }
        ]);

        var details = await _s.InvoiceQueries().DetailsAsync("FTR-000001", CancellationToken.None);

        Assert.Equal(["son", "düzeltme"], details!.Findings.Select(f => f.Details));
    }

    [Fact]
    public async Task Stuck_list_holds_exactly_the_invoices_the_summary_counts_as_stuck()
    {
        _s.Invoices.Add("FTR-000001", InvoiceStatus.Sent).UpdatedAt = Scenario.Start.AddMinutes(-3);
        _s.Invoices.Add("FTR-000002", InvoiceStatus.Processing).UpdatedAt = Scenario.Start.AddMinutes(-3);
        _s.Invoices.Add("FTR-000003", InvoiceStatus.Sent).UpdatedAt = Scenario.Start.AddMinutes(-1);
        _s.Invoices.Add("FTR-000004", InvoiceStatus.Failed).UpdatedAt = Scenario.Start.AddMinutes(-30);

        var queries = _s.InvoiceQueries();
        var list = await queries.ListAsync(null, null, true, 1, 20, CancellationToken.None);
        var summary = await queries.SummaryAsync(CancellationToken.None);

        Assert.Equal(["FTR-000001", "FTR-000002"], list.Items.Select(i => i.InvoiceNumber).Order());
        Assert.Equal(summary.StuckCount, list.TotalCount);

        var sentOnly = await queries.ListAsync(InvoiceStatus.Sent, null, true, 1, 20, CancellationToken.None);
        Assert.Equal(["FTR-000001"], sentOnly.Items.Select(i => i.InvoiceNumber));
    }

    [Fact]
    public async Task Details_bring_the_outbox_entry_the_events_and_the_findings_of_that_invoice_only()
    {
        _s.Invoices.Add("FTR-000001", InvoiceStatus.Sent);
        _s.Invoices.Add("FTR-000002", InvoiceStatus.Sent);
        _s.Outbox.Entries["FTR-000001"] = new ErpOutboxEntry
        {
            InvoiceNumber = "FTR-000001", Status = OutboxStatus.Completed, AttemptCount = 2
        };
        _s.Events.Events["evt-1"] = Event("evt-1", "FTR-000001");
        _s.Events.Events["evt-2"] = Event("evt-2", "FTR-000002");
        _s.Reconciliation.Findings.Add(Finding(1, "FTR-000001"));
        _s.Reconciliation.Findings.Add(Finding(2, "FTR-000002"));

        var details = await _s.InvoiceQueries().DetailsAsync("FTR-000001", CancellationToken.None);

        Assert.Equal(2, details!.Outbox!.AttemptCount);
        Assert.Equal(["evt-1"], details.Events.Select(e => e.EventId));
        Assert.Equal([1L], details.Findings.Select(f => f.Id));
    }

    [Fact]
    public async Task Details_of_an_invoice_without_an_outbox_entry_have_none_and_an_unknown_invoice_has_no_details()
    {
        _s.Invoices.Add("FTR-000001", InvoiceStatus.Failed);

        var details = await _s.InvoiceQueries().DetailsAsync("FTR-000001", CancellationToken.None);

        Assert.Null(details!.Outbox);
        Assert.Null(await _s.InvoiceQueries().DetailsAsync("FTR-999999", CancellationToken.None));
    }

    private static ErpWebhookEvent Event(string id, string invoice) => new()
    {
        EventId = id, EventType = WebhookEventType.Received, InvoiceNumber = invoice, ErpReference = "ERP-1",
        Status = WebhookEventStatus.Pending, Payload = "{}"
    };

    private static ReconciliationFinding Finding(long id, string invoice) => new()
    {
        Id = id, RunId = 1, InvoiceNumber = invoice, FindingType = FindingType.StuckInvoice,
        Action = FindingAction.Fixed, Details = "x"
    };
}
