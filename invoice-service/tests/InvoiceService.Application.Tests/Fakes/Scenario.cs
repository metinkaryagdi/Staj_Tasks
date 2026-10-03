using InvoiceService.Application.Invoices;
using InvoiceService.Application.Outbox;
using InvoiceService.Application.Webhooks;
using Microsoft.Extensions.Logging.Abstractions;
using Microsoft.Extensions.Options;

namespace InvoiceService.Application.Tests.Fakes;

/// <summary>The use cases wired to the in-memory ports, the way DI wires them to the database and the ERP.</summary>
public sealed class Scenario
{
    public static readonly DateTimeOffset Start = new(2026, 10, 3, 10, 0, 0, TimeSpan.Zero);

    public FixedTime Time { get; } = new(Start);
    public FakeUnitOfWork UnitOfWork { get; } = new();
    public FakeInvoiceStore Invoices { get; } = new();
    public FakeOutboxStore Outbox { get; } = new();
    public FakeWebhookEventStore Events { get; } = new();
    public FakeErpGateway Erp { get; } = new();

    public OutboxOptions OutboxSettings { get; } = new()
    {
        MaxConcurrentSends = 10, MaxAttempts = 3, MaxBackoffSeconds = 60, MaxJitterMilliseconds = 1000,
        BackoffMarginMilliseconds = 0, LockSeconds = 60, IdleDelayMilliseconds = 250
    };

    public WebhookOptions WebhookSettings { get; } = new()
    {
        Secret = new string('s', 32), ToleranceSeconds = 300, MaxBodyBytes = 65536,
        ResponseBudgetMilliseconds = 4000, LockTimeoutMilliseconds = 2000
    };

    public WebhookEventProcessor WebhookEventProcessor() => new(
        UnitOfWork, Events, Invoices, new InvoiceEventApplier(NullLogger<InvoiceEventApplier>.Instance), Time,
        Options.Create(WebhookSettings), NullLogger<WebhookEventProcessor>.Instance);

    public OutboxProcessor OutboxProcessor() => new(
        Outbox, Invoices, new ErpSendStrategy(Erp, Outbox, Time),
        new OutboxOutcomeWriter(UnitOfWork, Outbox, Invoices, WebhookEventProcessor()),
        new RetryPolicy(OutboxSettings), Options.Create(OutboxSettings), Time, NullLogger<OutboxProcessor>.Instance);

    public ResendInvoiceHandler ResendInvoiceHandler() => new(UnitOfWork, Invoices, Outbox, Time, NullLoggerFactory.Instance);

    public CreateInvoiceHandler CreateInvoiceHandler() => new(Invoices, Time, NullLoggerFactory.Instance);
}
