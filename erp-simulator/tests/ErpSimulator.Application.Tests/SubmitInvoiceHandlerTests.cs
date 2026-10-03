using ErpSimulator.Application.Invoices;
using ErpSimulator.Application.Simulation;
using ErpSimulator.Application.Tests.Fakes;
using ErpSimulator.Application.Webhooks;
using Microsoft.Extensions.Logging.Abstractions;
using Microsoft.Extensions.Options;

namespace ErpSimulator.Application.Tests;

/// <summary>One POST to the ERP with the database replaced by an in-memory store.</summary>
public class SubmitInvoiceHandlerTests
{
    private readonly FakeErpInvoiceStore _store = new();

    private SubmitInvoiceHandler Handler(BehaviorRates rates, bool idempotent = false)
    {
        var simulator = Options.Create(new SimulatorOptions
        {
            Seed = 42, Rates = rates, LateResponseDelaySeconds = 0, RetryAfterMinSeconds = 5, RetryAfterMaxSeconds = 30,
            IdempotentInvoices = idempotent
        });
        var webhooks = Options.Create(new WebhookOptions
        {
            Enabled = true, FirstEventMinSeconds = 2, FirstEventMaxSeconds = 10, SecondEventMinSeconds = 2,
            SecondEventMaxSeconds = 20, ApprovalRate = 100, RejectReasons = ["x"], Problems = new WebhookProblems()
        });
        return new SubmitInvoiceHandler(_store, new BehaviorSelector(simulator), new WebhookPlanner(webhooks, simulator),
            simulator, NullLoggerFactory.Instance);
    }

    private static BehaviorRates Only(Behavior behavior) => new()
    {
        Success = behavior == Behavior.Success ? 100 : 0, Busy = behavior == Behavior.Busy ? 100 : 0,
        ServerError = behavior == Behavior.ServerError ? 100 : 0, SaveThenError = behavior == Behavior.SaveThenError ? 100 : 0,
        LateResponse = behavior == Behavior.LateResponse ? 100 : 0
    };

    private static CreateInvoiceRequest Request(string customer = "C-001") =>
        new("INV-1", customer, 10.50m, "TRY", new DateOnly(2026, 9, 29));

    [Theory]
    [InlineData(Behavior.Success, 1)]
    [InlineData(Behavior.Busy, 0)]
    [InlineData(Behavior.ServerError, 0)]
    [InlineData(Behavior.SaveThenError, 1)]
    [InlineData(Behavior.LateResponse, 1)]
    public async Task Each_behavior_saves_or_not_as_documented(Behavior behavior, int saved)
    {
        var result = await Handler(Only(behavior)).HandleAsync(Request(), CancellationToken.None);

        Assert.Equal(SubmitOutcome.Decided, result.Outcome);
        Assert.Equal(behavior, result.Decision!.Behavior);
        Assert.Equal(saved, _store.Records.Count);
        // A saved invoice always gets its two events (received + decision).
        Assert.Equal(saved * 2, _store.Deliveries.Count);
    }

    [Fact]
    public async Task Invalid_request_draws_no_behavior()
    {
        var handler = Handler(Only(Behavior.Success));

        var invalid = await handler.HandleAsync(new CreateInvoiceRequest("", null, null, null, null), CancellationToken.None);
        var next = await handler.HandleAsync(Request(), CancellationToken.None);

        Assert.Equal(SubmitOutcome.Invalid, invalid.Outcome);
        Assert.Equal(1, next.Decision!.Sequence);
    }

    [Fact]
    public async Task Idempotent_repeat_with_the_same_content_returns_the_existing_record_without_drawing()
    {
        var handler = Handler(Only(Behavior.Success), idempotent: true);
        var first = await handler.HandleAsync(Request(), CancellationToken.None);

        var repeat = await handler.HandleAsync(Request(), CancellationToken.None);
        var after = await handler.HandleAsync(Request() with { InvoiceNumber = "INV-2" }, CancellationToken.None);

        Assert.Equal(SubmitOutcome.Duplicate, repeat.Outcome);
        Assert.Equal(first.Invoice!.ErpReference, repeat.Invoice!.ErpReference);
        Assert.Single(_store.Records, r => r.InvoiceNumber == "INV-1");
        Assert.Equal(2, after.Decision!.Sequence);
        Assert.Equal(["INV-1", "INV-1", "INV-2"], _store.Locked);
    }

    [Fact]
    public async Task Idempotent_repeat_with_other_content_is_a_conflict()
    {
        var handler = Handler(Only(Behavior.Success), idempotent: true);
        await handler.HandleAsync(Request(), CancellationToken.None);

        var conflict = await handler.HandleAsync(Request("C-999"), CancellationToken.None);

        Assert.Equal(SubmitOutcome.Conflict, conflict.Outcome);
        Assert.Single(_store.Records);
    }

    [Fact]
    public async Task Late_response_keeps_the_record_when_the_client_gives_up()
    {
        using var gone = new CancellationTokenSource();
        await gone.CancelAsync();
        var handler = Handler(Only(Behavior.LateResponse));

        var result = await handler.HandleAsync(Request(), gone.Token);

        Assert.True(result.ClientGone);
        Assert.Single(_store.Records);
    }
}
