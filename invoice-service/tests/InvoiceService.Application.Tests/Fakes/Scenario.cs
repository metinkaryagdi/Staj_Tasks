using InvoiceService.Application.Abstractions;
using InvoiceService.Application.Invoices;
using InvoiceService.Application.Outbox;
using InvoiceService.Application.Reconciliation;
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
        LockSeconds = 60, IdleDelayMilliseconds = 250
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

    public FakeReconciliationStore Reconciliation { get; }
    public FakeReconciliationLock Lock { get; } = new();

    public ReconciliationOptions ReconciliationSettings { get; } = new()
    {
        IntervalMinutes = 1, LookbackHours = 24, StuckAfterMinutes = 2, UnknownEventAfterMinutes = 60
    };

    public Scenario()
    {
        Reconciliation = new FakeReconciliationStore(Invoices, Events);
    }

    public FixApplier FixApplier() => new(UnitOfWork, Invoices, Outbox, Events, Reconciliation, WebhookEventProcessor(), Time);

    public ReconciliationPlanner ReconciliationPlanner() => new(Options.Create(ReconciliationSettings));

    /// <summary>Each scope gets its own FixApplier, as the container would.</summary>
    public FakeScopeFactory Scopes() => new(type =>
        type == typeof(FixApplier) ? FixApplier()
        : type == typeof(ReconciliationRunner) ? ReconciliationRunner()
        : type == typeof(IReconciliationStore) ? Reconciliation
        : type == typeof(IUnitOfWork) ? UnitOfWork
        : null);

    public ReconciliationRunner ReconciliationRunner() => new(
        Reconciliation, Erp, UnitOfWork, ReconciliationPlanner(), Scopes(), Options.Create(ReconciliationSettings), Time,
        NullLogger<ReconciliationRunner>.Instance);

    public ReconciliationService ReconciliationService() => new(Scopes(), Lock, Time, NullLogger<ReconciliationService>.Instance);

    public ResendInvoiceHandler ResendInvoiceHandler() => new(UnitOfWork, Invoices, Outbox, Time, NullLoggerFactory.Instance);

    public ResendInvoicesHandler ResendInvoicesHandler() => new(ResendInvoiceHandler(), NullLoggerFactory.Instance);

    public InvoiceQueries InvoiceQueries() => new(
        Invoices, Outbox, Events, Reconciliation, Options.Create(ReconciliationSettings), Time);

    public CreateInvoiceHandler CreateInvoiceHandler() => new(Invoices, Time, NullLoggerFactory.Instance);
}
