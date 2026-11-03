using ErpSimulator.Application.Invoices;
using ErpSimulator.Application.Simulation;
using ErpSimulator.Application.Tests.Fakes;
using ErpSimulator.Domain.Invoices;
using ErpSimulator.Domain.Webhooks;
using Microsoft.Extensions.Logging.Abstractions;
using Microsoft.Extensions.Options;

namespace ErpSimulator.Application.Tests;

/// <summary>One cancellation request with the database replaced by in-memory stores.</summary>
public class CancelInvoiceHandlerTests
{
    private static readonly DateTimeOffset Now = new(2026, 11, 3, 9, 0, 0, TimeSpan.Zero);

    private readonly FakeErpInvoiceStore _store = new();
    private readonly FakeDeliveryStore _deliveries = new();

    private CancelInvoiceHandler Handler(Behavior behavior)
    {
        var simulator = Options.Create(new SimulatorOptions
        {
            Seed = 42, LateResponseDelaySeconds = 0, RetryAfterMinSeconds = 5, RetryAfterMaxSeconds = 30,
            Rates = new BehaviorRates
            {
                Success = behavior == Behavior.Success ? 100 : 0, Busy = behavior == Behavior.Busy ? 100 : 0,
                ServerError = behavior == Behavior.ServerError ? 100 : 0,
                SaveThenError = behavior == Behavior.SaveThenError ? 100 : 0,
                LateResponse = behavior == Behavior.LateResponse ? 100 : 0
            }
        });
        var time = new FixedTime(Now);
        return new CancelInvoiceHandler(_store, new InvoiceLookup(_store, _deliveries, time), new BehaviorSelector(simulator),
            simulator, time, NullLoggerFactory.Instance);
    }

    private void Recorded(string invoiceNumber, string? decision = null)
    {
        _store.Records.Add(new ErpInvoice
        {
            Id = _store.Records.Count + 1, ErpReference = $"ERP-{_store.Records.Count + 1:D8}", InvoiceNumber = invoiceNumber,
            CustomerCode = "C-001", Amount = 10m, Currency = "TRY", InvoiceDate = new DateOnly(2026, 11, 3),
            ReceivedAt = Now.AddMinutes(-1), Behavior = nameof(Behavior.Success)
        });
        if (decision is not null)
        {
            _deliveries.Planned.Add(new WebhookDelivery
            {
                EventId = "evt-1", EventType = decision, InvoiceNumber = invoiceNumber, InvoiceId = _store.Records.Count,
                Kind = DeliveryKind.Normal, OccurredAt = Now.AddSeconds(-10), DueAt = Now, Status = DeliveryStatus.Delivered,
                Payload = """{"reason":"Müşteri kaydı bulunamadı"}"""
            });
        }
    }

    [Theory]
    [InlineData(null)]
    [InlineData(ErpEventType.Received)]
    [InlineData(ErpEventType.Approved)]
    public async Task A_recorded_invoice_that_is_not_rejected_is_cancelled(string? decision)
    {
        Recorded("FTR-000001", decision);

        var result = await Handler(Behavior.Success).HandleAsync("FTR-000001", CancellationToken.None);

        Assert.Equal(CancelOutcome.Decided, result.Outcome);
        Assert.Equal("IPT-00000001", Assert.Single(_store.Cancellations).CancelReference);
    }

    [Fact]
    public async Task An_unknown_invoice_is_not_cancelled_and_draws_no_behavior()
    {
        var result = await Handler(Behavior.Success).HandleAsync("FTR-000404", CancellationToken.None);

        Assert.Equal(CancelOutcome.NotFound, result.Outcome);
        Assert.Null(result.Decision);
        Assert.Empty(_store.Cancellations);
    }

    [Fact]
    public async Task A_rejected_invoice_is_not_cancelled_and_draws_no_behavior()
    {
        Recorded("FTR-000001", ErpEventType.Rejected);

        var result = await Handler(Behavior.Success).HandleAsync("FTR-000001", CancellationToken.None);

        Assert.Equal(CancelOutcome.Rejected, result.Outcome);
        Assert.Null(result.Decision);
        Assert.Empty(_store.Cancellations);
    }

    [Fact]
    public async Task The_same_cancellation_again_returns_the_first_record_and_saves_nothing()
    {
        Recorded("FTR-000001");
        var handler = Handler(Behavior.Success);
        var first = await handler.HandleAsync("FTR-000001", CancellationToken.None);

        var second = await handler.HandleAsync("FTR-000001", CancellationToken.None);

        Assert.Equal(CancelOutcome.Duplicate, second.Outcome);
        Assert.Null(second.Decision);
        Assert.Equal(first.Cancellation!.CancelReference, second.Cancellation!.CancelReference);
        Assert.Single(_store.Cancellations);
    }

    [Theory]
    [InlineData(Behavior.Success, 1)]
    [InlineData(Behavior.Busy, 0)]
    [InlineData(Behavior.ServerError, 0)]
    [InlineData(Behavior.SaveThenError, 1)]
    [InlineData(Behavior.LateResponse, 1)]
    public async Task Each_behavior_saves_the_cancellation_or_not_as_for_an_invoice(Behavior behavior, int saved)
    {
        Recorded("FTR-000001");

        var result = await Handler(behavior).HandleAsync("FTR-000001", CancellationToken.None);

        Assert.Equal(behavior, result.Decision!.Behavior);
        Assert.Equal(saved, _store.Cancellations.Count);
    }

    [Fact]
    public async Task A_cancellation_saved_with_an_error_is_found_by_the_retry_and_not_saved_again()
    {
        Recorded("FTR-000001");
        await Handler(Behavior.SaveThenError).HandleAsync("FTR-000001", CancellationToken.None);

        var retry = await Handler(Behavior.Success).HandleAsync("FTR-000001", CancellationToken.None);

        Assert.Equal(CancelOutcome.Duplicate, retry.Outcome);
        Assert.Single(_store.Cancellations);
    }

    [Fact]
    public async Task The_lookup_shows_the_cancellation()
    {
        Recorded("FTR-000001");
        await Handler(Behavior.Success).HandleAsync("FTR-000001", CancellationToken.None);

        var found = await new InvoiceLookup(_store, _deliveries, new FixedTime(Now)).FindAsync("FTR-000001", CancellationToken.None);

        Assert.Equal("IPT-00000001", found.Cancellation!.CancelReference);
    }
}
