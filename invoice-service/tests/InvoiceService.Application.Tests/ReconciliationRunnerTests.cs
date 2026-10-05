using InvoiceService.Application.Abstractions;
using InvoiceService.Application.Reconciliation;
using InvoiceService.Application.Tests.Fakes;
using InvoiceService.Domain.Invoices;
using InvoiceService.Domain.Reconciliation;
using InvoiceService.Domain.Webhooks;

namespace InvoiceService.Application.Tests;

/// <summary>A whole run against in-memory ports: what it reads, what it changes, and how it ends.</summary>
public class ReconciliationRunnerTests
{
    private static readonly DateTimeOffset Now = Scenario.Start;
    private readonly Scenario _s = new();

    private Invoice AddInvoice(string number, string status, int minutesInStatus = 10, string? reference = null, int createdHoursAgo = 1)
    {
        var invoice = _s.Invoices.Add(number, status, erpReference: reference);
        invoice.CreatedAt = Now.AddHours(-createdHoursAgo);
        invoice.UpdatedAt = Now.AddMinutes(-minutesInStatus);
        return invoice;
    }

    private static ErpRecord Erp(string number, string reference = "ERP-1") =>
        new(number, reference, "C-001", 10.50m, "TRY", new DateOnly(2026, 10, 1), Now.AddHours(-1));

    private ReconciliationRun StartRun() => _s.Reconciliation.StartRunAsync(Now, default).GetAwaiter().GetResult();

    private async Task<ReconciliationRun> RunAsync()
    {
        var run = StartRun();
        await _s.ReconciliationRunner().RunAsync(run, CancellationToken.None);
        return run;
    }

    private static ErpLookupResult Decided(string kind, string reference = "ERP-1", string? reason = null) =>
        new(ErpLookup.Found, reference, 200, null, TimeSpan.Zero, new ErpDecision(kind, reason, Now.AddMinutes(-5)));

    [Fact]
    public async Task A_run_fixes_what_it_can_reports_the_rest_and_counts_both()
    {
        AddInvoice("F-1", InvoiceStatus.Sent, reference: "ERP-1");
        AddInvoice("F-2", InvoiceStatus.Failed);
        AddInvoice("F-3", InvoiceStatus.Approved, reference: "ERP-3");
        _s.Events.Events["old"] = new ErpWebhookEvent
        {
            EventId = "old", EventType = WebhookEventType.Received, InvoiceNumber = "X-9", ErpReference = "ERP-9",
            Status = WebhookEventStatus.Pending, Payload = "{}", ReceivedAt = Now.AddMinutes(-90)
        };
        _s.Erp.ListResult = new ErpListResult(true,
            [Erp("F-1", "ERP-1"), Erp("F-2", "ERP-2"), Erp("F-3", "ERP-3"), Erp("X-1", "ERP-5")], null);
        _s.Erp.LookupResults.Enqueue(Decided(ErpDecisionKind.Approved, "ERP-1"));
        _s.Erp.LookupResults.Enqueue(Decided(ErpDecisionKind.Rejected, "ERP-2", "Mükerrer fatura"));

        var run = await RunAsync();

        Assert.Equal(ReconciliationStatus.Completed, run.Status);
        Assert.Null(run.Error);
        Assert.NotNull(run.FinishedAt);
        Assert.Equal(4, run.CheckedCount); // F-1, F-2, F-3 and X-1; an event is not an invoice
        Assert.Equal(3, run.FixedCount);
        Assert.Equal(1, run.ReportedCount);

        Assert.Equal(InvoiceStatus.Approved, _s.Invoices.Invoices["F-1"].Status);
        Assert.Equal(InvoiceStatus.Rejected, _s.Invoices.Invoices["F-2"].Status);
        Assert.Equal("ERP-2", _s.Invoices.Invoices["F-2"].ErpReference);
        Assert.Equal(WebhookEventStatus.Ignored, _s.Events.Events["old"].Status);

        var byType = _s.Reconciliation.Findings.ToDictionary(f => f.FindingType, f => f.Action);
        Assert.Equal(FindingAction.Fixed, byType[FindingType.StuckInvoice]);
        Assert.Equal(FindingAction.Fixed, byType[FindingType.FailedButInErp]);
        Assert.Equal(FindingAction.Fixed, byType[FindingType.UnknownEvent]);
        Assert.Equal(FindingAction.Reported, byType[FindingType.MissingInService]);
        Assert.All(_s.Reconciliation.Findings, f => Assert.Equal(run.Id, f.RunId));
    }

    [Fact]
    public async Task The_service_is_read_before_the_erp_and_the_window_is_the_lookback()
    {
        AddInvoice("F-1", InvoiceStatus.Approved, reference: "ERP-1");
        _s.Erp.ListResult = new ErpListResult(true, [Erp("F-1")], null);

        await RunAsync();

        var (from, to) = _s.Erp.LastListRange!.Value;
        Assert.Equal(Now.AddHours(-24), from);
        Assert.Equal(Now, to);
    }

    [Fact]
    public async Task An_invoice_older_than_the_window_that_the_erp_lists_is_not_missing_from_the_service()
    {
        AddInvoice("F-OLD", InvoiceStatus.Approved, reference: "ERP-1", createdHoursAgo: 30);
        _s.Erp.ListResult = new ErpListResult(true, [Erp("F-OLD", "ERP-1")], null);

        var run = await RunAsync();

        Assert.Empty(_s.Reconciliation.Findings);
        Assert.Equal(1, run.CheckedCount);
    }

    // --- Simülatöre ulaşılamazsa ---------------------------------------------------------------------------------------

    [Fact]
    public async Task When_the_erp_list_cannot_be_read_the_run_fails_and_nothing_is_changed()
    {
        AddInvoice("F-1", InvoiceStatus.Sent, reference: "ERP-1");
        AddInvoice("F-2", InvoiceStatus.Failed);
        _s.Erp.ListResult = new ErpListResult(false, [], "ERP kayıtları listelenemedi: ERP'ye ulaşılamadı");

        var run = await RunAsync();

        Assert.Equal(ReconciliationStatus.Failed, run.Status);
        Assert.Contains("ERP'ye ulaşılamadı", run.Error);
        Assert.Equal((0, 0, 0), (run.CheckedCount, run.FixedCount, run.ReportedCount));
        Assert.Equal(InvoiceStatus.Sent, _s.Invoices.Invoices["F-1"].Status);
        Assert.Equal(InvoiceStatus.Failed, _s.Invoices.Invoices["F-2"].Status);
        Assert.Empty(_s.Reconciliation.Findings);
        Assert.Equal(0, _s.UnitOfWork.Committed);
    }

    [Fact]
    public async Task When_one_decision_cannot_be_asked_for_not_even_the_invoices_asked_before_it_are_changed()
    {
        AddInvoice("F-1", InvoiceStatus.Sent, reference: "ERP-1");
        AddInvoice("F-2", InvoiceStatus.Sent, reference: "ERP-2");
        _s.Erp.ListResult = new ErpListResult(true, [Erp("F-1", "ERP-1"), Erp("F-2", "ERP-2")], null);
        _s.Erp.LookupResults.Enqueue(Decided(ErpDecisionKind.Approved, "ERP-1"));
        _s.Erp.LookupResults.Enqueue(FakeErpGateway.Unknown());

        var run = await RunAsync();

        Assert.Equal(ReconciliationStatus.Failed, run.Status);
        Assert.Contains("F-2", run.Error);
        Assert.Equal(InvoiceStatus.Sent, _s.Invoices.Invoices["F-1"].Status);
        Assert.Equal(InvoiceStatus.Sent, _s.Invoices.Invoices["F-2"].Status);
        Assert.Empty(_s.Reconciliation.Findings);
    }

    [Fact]
    public async Task A_run_that_is_stopped_is_recorded_as_failed()
    {
        AddInvoice("F-2", InvoiceStatus.Failed);
        _s.Erp.ListResult = new ErpListResult(true, [Erp("F-2", "ERP-2")], null);
        _s.Erp.LookupResults.Enqueue(Decided(ErpDecisionKind.Approved, "ERP-2"));
        var run = StartRun();
        using var stopped = new CancellationTokenSource();
        await stopped.CancelAsync();

        await _s.ReconciliationRunner().RunAsync(run, stopped.Token);

        Assert.Equal(ReconciliationStatus.Failed, run.Status);
        Assert.Contains("Servis durdu", run.Error);
        Assert.Equal(InvoiceStatus.Failed, _s.Invoices.Invoices["F-2"].Status);
    }

    // --- Mutabakat bir faturayı değiştirirken haber gelirse ------------------------------------------------------------

    [Fact]
    public async Task An_invoice_that_an_event_moved_after_the_erp_was_read_is_left_to_the_event()
    {
        AddInvoice("F-1", InvoiceStatus.Sent, reference: "ERP-1");
        _s.Erp.ListResult = new ErpListResult(true, [Erp("F-1", "ERP-1")], null);
        _s.Erp.LookupResults.Enqueue(Decided(ErpDecisionKind.Approved, "ERP-1"));
        // The event is applied after the decision was read and before the run writes.
        _s.Erp.OnFind = number => _s.Invoices.Invoices[number].Status = InvoiceStatus.Rejected;

        var run = await RunAsync();

        Assert.Equal(ReconciliationStatus.Completed, run.Status);
        Assert.Equal(InvoiceStatus.Rejected, _s.Invoices.Invoices["F-1"].Status);
        Assert.Equal(0, run.FixedCount);
        Assert.Empty(_s.Reconciliation.Findings);
    }

    [Fact]
    public async Task A_fix_that_fails_is_skipped_and_the_other_fixes_and_the_run_go_on()
    {
        AddInvoice("F-1", InvoiceStatus.Sent, reference: "ERP-1");
        AddInvoice("F-2", InvoiceStatus.Sent, reference: "ERP-2");
        _s.Invoices.FailLock.Add("F-1");
        _s.Erp.ListResult = new ErpListResult(true, [Erp("F-1", "ERP-1"), Erp("F-2", "ERP-2")], null);
        _s.Erp.LookupResults.Enqueue(Decided(ErpDecisionKind.Approved, "ERP-1"));
        _s.Erp.LookupResults.Enqueue(Decided(ErpDecisionKind.Approved, "ERP-2"));

        var run = await RunAsync();

        Assert.Equal(ReconciliationStatus.Completed, run.Status);
        Assert.Null(run.Error);
        Assert.Equal(1, run.FixedCount);
        Assert.Equal(InvoiceStatus.Sent, _s.Invoices.Invoices["F-1"].Status);
        Assert.Equal(InvoiceStatus.Approved, _s.Invoices.Invoices["F-2"].Status);
        Assert.Equal(["F-2"], _s.Reconciliation.Findings.Select(f => f.InvoiceNumber));
    }

    [Fact]
    public async Task Each_fix_gets_a_scope_of_its_own()
    {
        AddInvoice("F-1", InvoiceStatus.Sent, reference: "ERP-1");
        AddInvoice("F-2", InvoiceStatus.Sent, reference: "ERP-2");
        _s.Erp.ListResult = new ErpListResult(true, [Erp("F-1", "ERP-1"), Erp("F-2", "ERP-2")], null);
        _s.Erp.LookupResults.Enqueue(Decided(ErpDecisionKind.Approved, "ERP-1"));
        _s.Erp.LookupResults.Enqueue(Decided(ErpDecisionKind.Approved, "ERP-2"));
        var scopes = _s.Scopes();
        var runner = new ReconciliationRunner(
            _s.Reconciliation, _s.Erp, _s.UnitOfWork, _s.ReconciliationPlanner(), scopes,
            Microsoft.Extensions.Options.Options.Create(_s.ReconciliationSettings), _s.Time,
            Microsoft.Extensions.Logging.Abstractions.NullLogger<ReconciliationRunner>.Instance);

        await runner.RunAsync(StartRun(), CancellationToken.None);

        Assert.Equal(2, scopes.Created);
    }

    [Fact]
    public async Task A_run_with_nothing_to_compare_completes_with_zero_counts()
    {
        var run = await RunAsync();

        Assert.Equal(ReconciliationStatus.Completed, run.Status);
        Assert.Equal((0, 0, 0), (run.CheckedCount, run.FixedCount, run.ReportedCount));
    }
}
