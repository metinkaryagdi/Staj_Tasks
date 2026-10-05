using System.Security.Cryptography;
using System.Text.Json;
using ErpSimulator.Domain.Invoices;
using ErpSimulator.Domain.Webhooks;
using ErpSimulator.Application.Simulation;
using ErpSimulator.Application.Webhooks;
using Microsoft.Extensions.Configuration;
using Microsoft.Extensions.Options;

namespace ErpSimulator.Application.Tests;

public class WebhookPlannerTests
{
    private static readonly DateTimeOffset SavedAt = new(2026, 10, 2, 12, 0, 0, TimeSpan.Zero);

    // Same values as appsettings.json.
    private static WebhookOptions Defaults() => new()
    {
        Enabled = true,
        TargetUrl = "http://localhost:5090/api/v1/erp-webhooks",
        Secret = "dev-only-erp-webhook-secret-do-not-use-in-production",
        TimeoutSeconds = 5,
        RetryDelaysSeconds = [5, 10, 20, 40, 80],
        FirstEventMinSeconds = 2,
        FirstEventMaxSeconds = 10,
        SecondEventMinSeconds = 2,
        SecondEventMaxSeconds = 20,
        ApprovalRate = 80,
        RejectReasons = ["Vergi numarası geçersiz", "Mükerrer fatura"],
        MaxConcurrentSends = 20,
        PollMilliseconds = 200,
        Problems = new WebhookProblems { ReplayAgeSeconds = 600 } // every problem off unless a test turns it on
    };

    private static WebhookOptions WithProblems(Action<WebhookProblems> set)
    {
        var options = Defaults();
        set(options.Problems);
        return options;
    }

    private static WebhookPlanner Planner(WebhookOptions? options = null, int seed = 42) =>
        new(Options.Create(options ?? Defaults()), Options.Create(new SimulatorOptions { Seed = seed }));

    private static ErpInvoice Invoice(int i = 1) => new()
    {
        Id = i, ErpReference = $"ERP-{i:D8}", InvoiceNumber = $"FTR-{i:D6}", CustomerCode = "C-001", Currency = "TRY",
        Behavior = "Success"
    };

    [Fact]
    public void Each_invoice_gets_received_then_a_decision()
    {
        var events = Planner().Plan(Invoice(), SavedAt);
        Assert.Equal(2, events.Count);
        Assert.Equal(ErpEventType.Received, events[0].EventType);
        Assert.Contains(events[1].EventType, new[] { ErpEventType.Approved, ErpEventType.Rejected });
        Assert.NotEqual(events[0].EventId, events[1].EventId);
        Assert.All(events, e => Assert.Equal(DeliveryStatus.Pending, e.Status));
    }

    [Fact]
    public void Timing_stays_within_the_configured_ranges()
    {
        var planner = Planner();
        for (var i = 0; i < 2000; i++)
        {
            var events = planner.Plan(Invoice(i), SavedAt);
            var first = (events[0].DueAt - SavedAt).TotalSeconds;
            var second = (events[1].DueAt - events[0].DueAt).TotalSeconds;
            Assert.InRange(first, 2, 10);
            Assert.InRange(second, 2, 20);
            Assert.All(events, e => Assert.Equal(e.OccurredAt, e.DueAt));
        }
    }

    [Fact]
    public void About_80_percent_are_approved_and_every_rejection_has_a_reason()
    {
        var planner = Planner();
        var decisions = Enumerable.Range(0, 10_000).Select(i => planner.Plan(Invoice(i), SavedAt)[1]).ToList();
        var approved = decisions.Count(d => d.EventType == ErpEventType.Approved);
        Assert.InRange(approved, 7_800, 8_200);

        foreach (var d in decisions)
        {
            using var body = JsonDocument.Parse(d.Payload);
            var hasReason = body.RootElement.TryGetProperty("reason", out var reason);
            Assert.Equal(d.EventType == ErpEventType.Rejected, hasReason);
            if (hasReason)
                Assert.Contains(reason.GetString(), Defaults().RejectReasons);
        }
    }

    [Fact]
    public void Payload_has_the_documented_fields_in_snake_case()
    {
        var e = Planner().Plan(Invoice(7), SavedAt)[0];
        using var body = JsonDocument.Parse(e.Payload);
        var root = body.RootElement;
        Assert.Equal(e.EventId, root.GetProperty("event_id").GetString());
        Assert.Equal("invoice.received", root.GetProperty("event_type").GetString());
        Assert.Equal("FTR-000007", root.GetProperty("invoice_number").GetString());
        Assert.Equal("ERP-00000007", root.GetProperty("erp_reference").GetString());
        Assert.Equal(e.OccurredAt, root.GetProperty("occurred_at").GetDateTimeOffset());
        Assert.False(root.TryGetProperty("reason", out _));
    }

    [Fact]
    public void Same_seed_gives_the_same_plan()
    {
        var a = Planner(seed: 5).Plan(Invoice(), SavedAt);
        var b = Planner(seed: 5).Plan(Invoice(), SavedAt);
        Assert.Equal(a.Select(e => (e.EventType, e.DueAt)), b.Select(e => (e.EventType, e.DueAt)));
    }

    [Fact]
    public void Signature_is_hex_hmac_of_timestamp_dot_body()
    {
        // The invoice service checks exactly this format.
        Assert.Equal(
            Convert.ToHexStringLower(HMACSHA256.HashData("key"u8, "1.{}"u8)),
            WebhookSignature.Compute("key", "1", "{}"u8));
    }

    private static bool Validates(Action<Dictionary<string, string?>> change)
    {
        var values = new Dictionary<string, string?>
        {
            ["Webhooks:Enabled"] = "true",
            ["Webhooks:TargetUrl"] = "http://localhost:5090/api/v1/erp-webhooks",
            ["Webhooks:Secret"] = "dev-only-erp-webhook-secret-do-not-use-in-production",
            ["Webhooks:TimeoutSeconds"] = "5",
            ["Webhooks:RetryDelaysSeconds:0"] = "5",
            ["Webhooks:RetryDelaysSeconds:1"] = "10",
            ["Webhooks:FirstEventMinSeconds"] = "2",
            ["Webhooks:FirstEventMaxSeconds"] = "10",
            ["Webhooks:SecondEventMinSeconds"] = "2",
            ["Webhooks:SecondEventMaxSeconds"] = "20",
            ["Webhooks:ApprovalRate"] = "80",
            ["Webhooks:RejectReasons:0"] = "Vergi numarası geçersiz",
            ["Webhooks:MaxConcurrentSends"] = "20",
            ["Webhooks:PollMilliseconds"] = "200",
            ["Webhooks:Problems:DuplicateRate"] = "10",
            ["Webhooks:Problems:OrderMixRate"] = "15",
            ["Webhooks:Problems:LostDecisionRate"] = "5",
            ["Webhooks:Problems:FakeRate"] = "5",
            ["Webhooks:Problems:ReplayRate"] = "5",
            ["Webhooks:Problems:ReplayAgeSeconds"] = "600"
        };
        change(values);
        var configuration = new ConfigurationBuilder().AddInMemoryCollection(values).Build();
        var options = new WebhookOptions();
        configuration.GetSection(WebhookOptions.SectionName).Bind(options);
        return new WebhookOptionsValidator(configuration).Validate(null, options).Succeeded;
    }

    [Fact]
    public void Settings_file_values_are_valid() => Assert.True(Validates(_ => { }));

    [Theory]
    [InlineData("Webhooks:TargetUrl", "not a url")]
    [InlineData("Webhooks:Secret", "short")]
    [InlineData("Webhooks:TimeoutSeconds", "0")]
    [InlineData("Webhooks:FirstEventMaxSeconds", "1")]
    [InlineData("Webhooks:ApprovalRate", "101")]
    [InlineData("Webhooks:MaxConcurrentSends", null)]
    [InlineData("Webhooks:Problems:FakeRate", "-1")]
    [InlineData("Webhooks:Problems:ReplayRate", "NaN")]
    [InlineData("Webhooks:Problems:ReplayAgeSeconds", "0")]
    [InlineData("Webhooks:Problems:DuplicateRate", null)]
    public void Invalid_settings_stop_the_app(string key, string? value) =>
        Assert.False(Validates(v => v[key] = value));

    [Fact]
    public void Disabled_plans_nothing()
    {
        var options = Defaults();
        options.Enabled = false;
        Assert.Empty(Planner(options).Plan(Invoice(), SavedAt));
    }

    // --- Problems ---------------------------------------------------------------------------------------------------

    [Fact]
    public void Order_mix_sends_the_decision_first()
    {
        var planner = Planner(WithProblems(p => p.OrderMixRate = 100));
        for (var i = 0; i < 2000; i++)
        {
            var events = planner.Plan(Invoice(i), SavedAt);
            Assert.Equal(2, events.Count);
            var received = events[0];
            var decision = events[1];
            Assert.Equal(ErpEventType.Received, received.EventType);
            Assert.True(decision.DueAt < received.DueAt);
            Assert.True(received.OccurredAt < decision.OccurredAt);
            Assert.True(received.OccurredAt >= SavedAt);
            Assert.Equal(decision.DueAt, decision.OccurredAt);
            Assert.InRange((decision.DueAt - SavedAt).TotalSeconds, 2, 10);
            Assert.InRange((received.DueAt - decision.DueAt).TotalSeconds, 2, 20);
            foreach (var row in events)
            {
                using var body = JsonDocument.Parse(row.Payload);
                Assert.Equal(row.OccurredAt, body.RootElement.GetProperty("occurred_at").GetDateTimeOffset());
            }
        }
    }

    [Fact]
    public void Order_mix_does_nothing_when_the_decision_is_lost()
    {
        var planner = Planner(WithProblems(p => { p.OrderMixRate = 100; p.LostDecisionRate = 100; }));
        for (var i = 0; i < 500; i++)
        {
            var events = planner.Plan(Invoice(i), SavedAt);
            var received = Assert.Single(events, e => e.EventType == ErpEventType.Received);
            Assert.InRange((received.DueAt - SavedAt).TotalSeconds, 2, 10);
        }
    }

    [Fact]
    public void Lost_decision_is_written_but_never_due_to_be_sent()
    {
        var events = Planner(WithProblems(p => { p.LostDecisionRate = 100; p.DuplicateRate = 100; })).Plan(Invoice(), SavedAt);
        var decision = Assert.Single(events, e => e.EventType != ErpEventType.Received);
        Assert.Equal(DeliveryKind.LostDecision, decision.Kind);
        Assert.Equal(DeliveryStatus.Skipped, decision.Status);
        // Only invoice.received is duplicated; a lost decision has nothing to duplicate.
        Assert.Equal(2, events.Count(e => e.EventType == ErpEventType.Received));
    }

    [Fact]
    public void Duplicate_repeats_the_same_event_id_and_body_within_two_seconds()
    {
        var events = Planner(WithProblems(p => p.DuplicateRate = 100)).Plan(Invoice(), SavedAt);
        Assert.Equal(4, events.Count);
        foreach (var copy in events.Where(e => e.Kind == DeliveryKind.Duplicate))
        {
            var original = Assert.Single(events, e => e.Kind == DeliveryKind.Normal && e.EventId == copy.EventId);
            Assert.Equal(original.Payload, copy.Payload);
            Assert.InRange((copy.DueAt - original.DueAt).TotalSeconds, 0, 2);
        }
    }

    [Fact]
    public void Fake_is_a_decision_with_its_own_event_id()
    {
        var events = Planner(WithProblems(p => p.FakeRate = 100)).Plan(Invoice(), SavedAt);
        var fake = Assert.Single(events, e => e.Kind == DeliveryKind.Fake);
        Assert.NotEqual(ErpEventType.Received, fake.EventType);
        Assert.DoesNotContain(events, e => e != fake && e.EventId == fake.EventId);
        Assert.InRange((fake.DueAt - SavedAt).TotalSeconds, 2, 30);
    }

    [Fact]
    public void Replay_repeats_an_event_one_to_five_seconds_after_it()
    {
        var events = Planner(WithProblems(p => p.ReplayRate = 100)).Plan(Invoice(), SavedAt);
        var replay = Assert.Single(events, e => e.Kind == DeliveryKind.Replay);
        var original = Assert.Single(events, e => e.Kind == DeliveryKind.Normal && e.EventId == replay.EventId);
        Assert.Equal(original.Payload, replay.Payload);
        Assert.Equal(original.OccurredAt, replay.OccurredAt);
        Assert.Equal(DeliveryStatus.Waiting, replay.Status);
        Assert.InRange((replay.DueAt - original.DueAt).TotalSeconds, 1, 5);
    }

    [Fact]
    public void Only_replays_wait_and_lost_decisions_are_skipped()
    {
        var planner = Planner(WithProblems(p =>
        {
            p.ReplayRate = 100; p.LostDecisionRate = 100; p.DuplicateRate = 100; p.FakeRate = 100;
        }));
        Assert.All(planner.Plan(Invoice(), SavedAt), row => Assert.Equal(
            row.Kind == DeliveryKind.Replay ? DeliveryStatus.Waiting
                : row.Kind == DeliveryKind.LostDecision ? DeliveryStatus.Skipped : DeliveryStatus.Pending, row.Status));
    }

    [Fact]
    public void Problem_choices_do_not_shift_the_random_draws_for_later_invoices()
    {
        var normal = Planner();
        var problems = Planner(WithProblems(p =>
        {
            p.OrderMixRate = 100; p.ReplayRate = 100; p.DuplicateRate = 100; p.FakeRate = 100;
        }));
        for (var i = 0; i < 500; i++)
        {
            var a = normal.Plan(Invoice(i), SavedAt);
            var b = problems.Plan(Invoice(i), SavedAt);
            Assert.Equal(a[0].DueAt, b[1].DueAt);
            Assert.Equal(a[1].DueAt, b[0].DueAt);
            Assert.Equal(a[1].EventType, b[1].EventType);
        }
    }

    [Fact]
    public void Default_rates_come_out_independently()
    {
        var options = WithProblems(p =>
        {
            p.DuplicateRate = 10; p.OrderMixRate = 15; p.LostDecisionRate = 5; p.FakeRate = 5; p.ReplayRate = 5;
        });
        var planner = Planner(options);
        var plans = Enumerable.Range(0, 10_000).Select(i => planner.Plan(Invoice(i), SavedAt)).ToList();

        var lost = plans.Count(p => p.Any(e => e.Kind == DeliveryKind.LostDecision));
        var fake = plans.Count(p => p.Any(e => e.Kind == DeliveryKind.Fake));
        var replay = plans.Count(p => p.Any(e => e.Kind == DeliveryKind.Replay));
        // Order mix shows only where a decision is sent (a lost decision has nothing to reorder).
        var withDecision = plans.Where(p => !p.Any(e => e.Kind == DeliveryKind.LostDecision)).ToList();
        var mixed = withDecision.Count(p => p[1].DueAt < p[0].DueAt);
        var duplicates = plans.Sum(p => p.Count(e => e.Kind == DeliveryKind.Duplicate));
        var sentEvents = plans.Sum(p => p.Count(e => e.Kind == DeliveryKind.Normal));

        Assert.InRange(lost, 400, 600);
        Assert.InRange(fake, 400, 600);
        Assert.InRange(replay, 400, 600);
        Assert.InRange(duplicates * 100.0 / sentEvents, 9, 11);
        // Independent of the lost-decision draw: still about 15 % among the invoices that keep their decision.
        Assert.InRange(mixed * 100.0 / withDecision.Count, 13.5, 16.5);
        // Independent of each other: about 5 % x 5 % = 0.25 % of the invoices get both a fake and a replayed event.
        var fakeAndReplay = plans.Count(p => p.Any(e => e.Kind == DeliveryKind.Fake) && p.Any(e => e.Kind == DeliveryKind.Replay));
        Assert.InRange(fakeAndReplay, 10, 45);
    }
}
