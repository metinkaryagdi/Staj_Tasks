using System.Security.Cryptography;
using System.Text.Json;
using ErpSimulator.Data;
using ErpSimulator.Simulation;
using ErpSimulator.Webhooks;
using Microsoft.Extensions.Configuration;
using Microsoft.Extensions.Options;

namespace ErpSimulator.Tests;

public class WebhookPlannerTests
{
    private static readonly DateTimeOffset SavedAt = new(2026, 10, 2, 12, 0, 0, TimeSpan.Zero);

    // Same values as appsettings.json.
    private static WebhookOptions Defaults() => new()
    {
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
        PollMilliseconds = 200
    };

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
    public void Timing_stays_within_the_task_ranges()
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
    public void Payload_has_the_task_fields_in_snake_case()
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
            ["Webhooks:PollMilliseconds"] = "200"
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
    public void Invalid_settings_stop_the_app(string key, string? value) =>
        Assert.False(Validates(v => v[key] = value));
}
