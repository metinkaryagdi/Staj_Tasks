using InvoiceService.Application.Abstractions;
using InvoiceService.Application.Reconciliation;
using InvoiceService.Domain.Invoices;
using InvoiceService.Domain.Reconciliation;
using InvoiceService.Domain.Webhooks;
using Microsoft.Extensions.Options;

namespace InvoiceService.Application.Tests;

/// <summary>What a run finds and fixes, from a snapshot of both sides; no database, no ERP.</summary>
public class ReconciliationPlannerTests
{
    private static readonly DateTimeOffset Now = new(2026, 10, 5, 12, 0, 0, TimeSpan.Zero);

    private static readonly ReconciliationPlanner Planner = new(Options.Create(new ReconciliationOptions
    {
        IntervalMinutes = 1, LookbackHours = 24, StuckAfterMinutes = 2, UnknownEventAfterMinutes = 60,
        NoDecisionAfterMinutes = 30
    }));

    private static Invoice Invoice(string number, string status, int minutesInStatus = 10, string? reference = null,
        decimal amount = 100m, string currency = "TRY", string customer = "C-001") => new()
    {
        InvoiceNumber = number, Status = status, Amount = amount, Currency = currency, CustomerCode = customer,
        ErpReference = reference, UpdatedAt = Now.AddMinutes(-minutesInStatus)
    };

    private static ErpRecord Erp(string number, string reference = "ERP-1", decimal amount = 100m, string currency = "TRY",
        string customer = "C-001") => new(number, reference, customer, amount, currency, new DateOnly(2026, 10, 5), Now.AddHours(-1));

    private static ErpWebhookEvent Event(string number, int minutesAgo, string id = "evt-1") => new()
    {
        EventId = id, EventType = WebhookEventType.Received, InvoiceNumber = number, ErpReference = "ERP-9",
        Status = WebhookEventStatus.Pending, Payload = "{}", ReceivedAt = Now.AddMinutes(-minutesAgo)
    };

    private static ReconciliationSnapshot Snapshot(IEnumerable<Invoice>? invoices = null, IEnumerable<ErpRecord>? erp = null,
        IEnumerable<ErpWebhookEvent>? events = null) =>
        new(Now, (invoices ?? []).ToList(), (erp ?? []).ToList(), (events ?? []).ToList());

    private static ReconciliationPlan Plan(ReconciliationSnapshot snapshot, params (string Number, ErpDecision Decision)[] decisions) =>
        Planner.Plan(snapshot, decisions.ToDictionary(d => d.Number, d => d.Decision));

    private static ErpDecision Decided(string kind, string? reason = null) => new(kind, reason, Now.AddMinutes(-5));

    // --- Gönderildi ya da İşleme Alındı'da 2 dakikadan uzun kalan ---------------------------------------------------

    [Theory]
    [InlineData(InvoiceStatus.Sent, ErpDecisionKind.Approved, InvoiceStatus.Approved)]
    [InlineData(InvoiceStatus.Sent, ErpDecisionKind.Rejected, InvoiceStatus.Rejected)]
    [InlineData(InvoiceStatus.Sent, ErpDecisionKind.Received, InvoiceStatus.Processing)]
    [InlineData(InvoiceStatus.Processing, ErpDecisionKind.Approved, InvoiceStatus.Approved)]
    [InlineData(InvoiceStatus.Processing, ErpDecisionKind.Rejected, InvoiceStatus.Rejected)]
    public void A_stuck_invoice_takes_the_erps_decision_by_the_rules_of_an_event(string status, string kind, string expected)
    {
        var snapshot = Snapshot([Invoice("F-1", status)], [Erp("F-1")]);

        var plan = Plan(snapshot, ("F-1", Decided(kind, kind == ErpDecisionKind.Rejected ? "Mükerrer fatura" : null)));

        var finding = Assert.Single(plan.Findings);
        Assert.Equal(FindingType.StuckInvoice, finding.FindingType);
        Assert.Equal(FixKind.ApplyDecision, finding.Fix!.Kind);
        Assert.Equal(status, finding.Fix.ExpectedStatus);
        Assert.Contains(expected, finding.Details);
        Assert.Equal(expected, ReconciliationPlanner.DecisionTarget(status, finding.Fix.Decision!));
    }

    [Theory]
    [InlineData(ErpDecisionKind.None)]
    [InlineData(ErpDecisionKind.Received)]
    public void An_invoice_the_erp_has_not_decided_on_is_left_alone_until_the_no_decision_threshold(string kind)
    {
        // İşleme Alındı + received: a second invoice.received would not move it forward either.
        var snapshot = Snapshot([Invoice("F-1", InvoiceStatus.Processing, minutesInStatus: 30)], [Erp("F-1")]);

        Assert.Empty(Plan(snapshot, ("F-1", Decided(kind))).Findings);
    }

    [Theory]
    [InlineData(InvoiceStatus.Sent, ErpDecisionKind.None)]
    [InlineData(InvoiceStatus.Processing, ErpDecisionKind.None)]
    [InlineData(InvoiceStatus.Processing, ErpDecisionKind.Received)]
    public void A_stuck_invoice_without_a_decision_after_the_threshold_is_reported_and_not_changed(string status, string kind)
    {
        var snapshot = Snapshot([Invoice("F-1", status, minutesInStatus: 31)], [Erp("F-1")]);

        var finding = Assert.Single(Plan(snapshot, ("F-1", Decided(kind))).Findings);

        Assert.Equal(FindingType.NoErpDecision, finding.FindingType);
        Assert.Null(finding.Fix);
        Assert.Contains($"{status} durumunda 31 dk", finding.Details);
        Assert.Contains($"ERP cevabı: {kind}", finding.Details);
    }

    [Fact]
    public void A_sent_invoice_the_erp_only_received_moves_on_instead_of_being_reported()
    {
        var snapshot = Snapshot([Invoice("F-1", InvoiceStatus.Sent, minutesInStatus: 45)], [Erp("F-1")]);

        var finding = Assert.Single(Plan(snapshot, ("F-1", Decided(ErpDecisionKind.Received))).Findings);

        Assert.Equal(FindingType.StuckInvoice, finding.FindingType);
    }

    [Fact]
    public void An_invoice_is_stuck_only_after_more_than_the_threshold()
    {
        var atTheLimit = Snapshot([Invoice("F-1", InvoiceStatus.Sent, minutesInStatus: 2)], [Erp("F-1")]);
        var past = Snapshot([Invoice("F-1", InvoiceStatus.Sent, minutesInStatus: 3)], [Erp("F-1")]);

        Assert.Empty(Planner.InvoicesToAsk(atTheLimit));
        Assert.Equal(["F-1"], Planner.InvoicesToAsk(past));
    }

    [Fact]
    public void An_invoice_that_is_already_decided_or_not_sent_yet_is_not_asked_about()
    {
        var snapshot = Snapshot(
            [Invoice("F-1", InvoiceStatus.Approved), Invoice("F-2", InvoiceStatus.Rejected), Invoice("F-3", InvoiceStatus.Pending)],
            [Erp("F-1", "ERP-1"), Erp("F-2", "ERP-2"), Erp("F-3", "ERP-3")]);

        Assert.Empty(Planner.InvoicesToAsk(snapshot));
        Assert.Empty(Plan(snapshot).Findings);
    }

    [Fact]
    public void A_stuck_invoice_whose_reference_differs_is_reported_not_fixed()
    {
        var snapshot = Snapshot([Invoice("F-1", InvoiceStatus.Sent, reference: "ERP-7")], [Erp("F-1", "ERP-1")]);

        var plan = Plan(snapshot, ("F-1", Decided(ErpDecisionKind.Approved)));

        var finding = Assert.Single(plan.Findings);
        Assert.Equal(FindingType.FieldMismatch, finding.FindingType);
        Assert.Null(finding.Fix);
        Assert.Contains("erp_reference", finding.Details);
        Assert.Empty(Planner.InvoicesToAsk(snapshot));
    }

    // --- Serviste Başarısız ama ERP'de kayıtlı
    // ------------------------------------------------------------------------

    [Fact]
    public void A_failed_invoice_the_erp_has_is_recovered_with_the_erps_reference_and_decision()
    {
        var snapshot = Snapshot([Invoice("F-1", InvoiceStatus.Failed)], [Erp("F-1", "ERP-42")]);

        var plan = Plan(snapshot, ("F-1", Decided(ErpDecisionKind.Approved)));

        var finding = Assert.Single(plan.Findings);
        Assert.Equal(FindingType.FailedButInErp, finding.FindingType);
        Assert.Equal(FixKind.RecoverFailed, finding.Fix!.Kind);
        Assert.Equal("ERP-42", finding.Fix.ErpReference);
        Assert.Equal(ErpDecisionKind.Approved, finding.Fix.Decision!.Kind);
        Assert.Contains("Gönderildi", finding.Details);
        Assert.Contains("Onaylandı", finding.Details);
    }

    [Fact]
    public void A_failed_invoice_without_a_decision_still_becomes_sent()
    {
        var snapshot = Snapshot([Invoice("F-1", InvoiceStatus.Failed)], [Erp("F-1", "ERP-42")]);

        var finding = Assert.Single(Plan(snapshot, ("F-1", ErpDecision.None)).Findings);

        Assert.Equal(FixKind.RecoverFailed, finding.Fix!.Kind);
        Assert.DoesNotContain("Onaylandı", finding.Details);
    }

    [Fact]
    public void A_failed_invoice_the_erp_does_not_have_is_left_alone()
    {
        Assert.Empty(Plan(Snapshot([Invoice("F-1", InvoiceStatus.Failed)])).Findings);
    }

    [Fact]
    public void A_failed_invoice_whose_content_differs_from_the_erps_is_reported_not_recovered()
    {
        var snapshot = Snapshot([Invoice("F-1", InvoiceStatus.Failed)], [Erp("F-1", amount: 999m)]);

        var finding = Assert.Single(Plan(snapshot).Findings);

        Assert.Equal(FindingType.FieldMismatch, finding.FindingType);
        Assert.Null(finding.Fix);
    }

    // --- Servisin tanımadığı faturaya ait, 1 saatten eski bekleyen haber
    // -----------------------------------------------

    [Fact]
    public void A_waiting_event_for_an_unknown_invoice_is_ignored_only_after_the_threshold()
    {
        var snapshot = Snapshot(events: [Event("X-1", minutesAgo: 61, id: "old"), Event("X-2", minutesAgo: 60, id: "limit"),
                                         Event("X-3", minutesAgo: 5, id: "new")]);

        var finding = Assert.Single(Plan(snapshot).Findings);

        Assert.Equal(FindingType.UnknownEvent, finding.FindingType);
        Assert.Equal(FixKind.IgnoreEvent, finding.Fix!.Kind);
        Assert.Equal("old", finding.Fix.EventId);
        Assert.Equal("X-1", finding.InvoiceNumber);
    }

    // --- ERP'de olup serviste hiç olmayan ----------------------------------------------------------------------------

    [Fact]
    public void An_erp_record_the_service_does_not_have_is_reported()
    {
        var finding = Assert.Single(Plan(Snapshot(erp: [Erp("X-1", "ERP-5")])).Findings);

        Assert.Equal(FindingType.MissingInService, finding.FindingType);
        Assert.Null(finding.Fix);
        Assert.Contains("ERP-5", finding.Details);
    }

    [Fact]
    public void An_invoice_the_service_says_was_sent_but_the_erp_does_not_have_is_reported()
    {
        var snapshot = Snapshot([Invoice("F-1", InvoiceStatus.Sent), Invoice("F-2", InvoiceStatus.Approved),
                                 Invoice("F-3", InvoiceStatus.Pending)]);

        var plan = Plan(snapshot);

        Assert.Equal(["F-1", "F-2"], plan.Findings.Select(f => f.InvoiceNumber));
        Assert.All(plan.Findings, f => Assert.Equal(FindingType.MissingInErp, f.FindingType));
        Assert.All(plan.Findings, f => Assert.Null(f.Fix));
    }

    // --- ERP'de birden fazla kaydı olan
    // --------------------------------------------------------------------------------

    [Fact]
    public void An_invoice_with_two_erp_records_is_reported_and_otherwise_compared_with_the_first()
    {
        var snapshot = Snapshot([Invoice("F-1", InvoiceStatus.Approved, reference: "ERP-1")],
            [Erp("F-1", "ERP-1"), Erp("F-1", "ERP-2")]);

        var finding = Assert.Single(Plan(snapshot).Findings);

        Assert.Equal(FindingType.DuplicateInErp, finding.FindingType);
        Assert.Null(finding.Fix);
        Assert.Contains("ERP-1, ERP-2", finding.Details);
    }

    [Theory]
    [InlineData(InvoiceStatus.Failed)]
    [InlineData(InvoiceStatus.Sent)]
    [InlineData(InvoiceStatus.Processing)]
    public void An_invoice_the_erp_has_twice_is_only_reported_even_when_it_would_otherwise_be_fixed(string status)
    {
        // Failed, or stuck for ten minutes: with one ERP record it would be recovered or take the ERP's decision.
        var snapshot = Snapshot([Invoice("F-1", status)], [Erp("F-1", "ERP-1"), Erp("F-1", "ERP-2")]);

        var plan = Plan(snapshot, ("F-1", Decided(ErpDecisionKind.Approved)));

        var finding = Assert.Single(plan.Findings);
        Assert.Equal(FindingType.DuplicateInErp, finding.FindingType);
        Assert.Null(finding.Fix);
        Assert.Empty(Planner.InvoicesToAsk(snapshot));
    }

    [Fact]
    public void A_duplicated_record_the_service_does_not_have_is_reported_as_missing_and_as_duplicated()
    {
        var plan = Plan(Snapshot(erp: [Erp("X-1", "ERP-1"), Erp("X-1", "ERP-2")]));

        Assert.Equal([FindingType.MissingInService, FindingType.DuplicateInErp], plan.Findings.Select(f => f.FindingType));
    }

    // --- Tutar, para birimi, müşteri kodu ya da erp_reference farklı
    // ---------------------------------------------------

    [Theory]
    [InlineData("tutar", 105.5, "TRY", "C-001")]
    [InlineData("para birimi", 100, "EUR", "C-001")]
    [InlineData("müşteri kodu", 100, "TRY", "C-002")]
    public void A_difference_in_a_compared_field_is_reported_and_nothing_changes(string field, double amount, string currency, string customer)
    {
        var snapshot = Snapshot([Invoice("F-1", InvoiceStatus.Approved, reference: "ERP-1")],
            [Erp("F-1", "ERP-1", (decimal)amount, currency, customer)]);

        var finding = Assert.Single(Plan(snapshot).Findings);

        Assert.Equal(FindingType.FieldMismatch, finding.FindingType);
        Assert.Null(finding.Fix);
        Assert.Contains(field, finding.Details);
    }

    [Fact]
    public void Several_differences_are_one_finding_and_a_service_without_a_reference_has_no_reference_difference()
    {
        var snapshot = Snapshot([Invoice("F-1", InvoiceStatus.Approved, reference: "ERP-7", amount: 1m, currency: "EUR"),
                                 Invoice("F-2", InvoiceStatus.Failed, reference: null)],
            [Erp("F-1", "ERP-1"), Erp("F-2", "ERP-2")]);

        var plan = Plan(snapshot, ("F-2", ErpDecision.None));

        var mismatch = plan.Findings.Single(f => f.InvoiceNumber == "F-1");
        Assert.Contains("tutar", mismatch.Details);
        Assert.Contains("para birimi", mismatch.Details);
        Assert.Contains("erp_reference", mismatch.Details);
        Assert.Equal(FindingType.FailedButInErp, plan.Findings.Single(f => f.InvoiceNumber == "F-2").FindingType);
    }

    [Fact]
    public void An_invoice_that_matches_the_erp_has_no_finding()
    {
        var snapshot = Snapshot([Invoice("F-1", InvoiceStatus.Approved, reference: "ERP-1")], [Erp("F-1", "ERP-1")]);

        Assert.Empty(Plan(snapshot).Findings);
    }

    // --- Sayım
    // ---------------------------------------------------------------------------------------------------------

    [Fact]
    public void The_checked_count_is_the_distinct_invoice_numbers_of_both_sides()
    {
        var snapshot = Snapshot([Invoice("F-1", InvoiceStatus.Approved, reference: "ERP-1"), Invoice("F-2", InvoiceStatus.Pending)],
            [Erp("F-1", "ERP-1"), Erp("F-1", "ERP-1b"), Erp("X-1", "ERP-5")]);

        Assert.Equal(3, Plan(snapshot).CheckedCount);
    }
}
