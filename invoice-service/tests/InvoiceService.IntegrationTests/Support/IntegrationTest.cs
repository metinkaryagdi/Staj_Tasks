using System.Text.Json;
using InvoiceService.Application;
using InvoiceService.Application.Invoices;
using InvoiceService.Application.Outbox;
using InvoiceService.Application.Reconciliation;
using InvoiceService.Application.Webhooks;
using InvoiceService.Domain.Webhooks;
using InvoiceService.Infrastructure;
using InvoiceService.Infrastructure.Persistence;
using Microsoft.Extensions.DependencyInjection;
using Npgsql;

namespace InvoiceService.IntegrationTests.Support;

/// <summary>
/// What every test starts from: its own empty database and its own fake ERP. <see cref="NewScope"/> gives the objects of
/// one service copy (a DI scope, as a worker or a request has); two scopes are two copies working on the same database.
/// </summary>
[Collection(DatabaseCollection.Name)]
public abstract class IntegrationTest(PostgresFixture postgres) : IAsyncLifetime
{
    private string _databaseName = "";
    private ServiceProvider _provider = null!;

    protected FakeErp Erp { get; private set; } = null!;
    protected string ConnectionString { get; private set; } = "";

    public async Task InitializeAsync()
    {
        (_databaseName, ConnectionString) = await postgres.CreateDatabaseAsync();
        Erp = await FakeErp.StartAsync();

        var configuration = TestSettings.Build(ConnectionString, Erp.BaseUrl);
        var services = new ServiceCollection();
        services.AddLogging();
        services.AddSingleton(configuration);
        services.AddInvoiceApplication(configuration);
        services.AddInvoiceInfrastructure(configuration);
        _provider = services.BuildServiceProvider();
    }

    public async Task DisposeAsync()
    {
        await _provider.DisposeAsync();
        await Erp.DisposeAsync();
        await postgres.DropDatabaseAsync(_databaseName);
    }

    protected AsyncServiceScope NewScope() => _provider.CreateAsyncScope();

    /// <summary>A plain connection to the test database for reading what the service wrote and for setting up rows.</summary>
    protected async Task<NpgsqlConnection> OpenConnectionAsync()
    {
        var connection = new NpgsqlConnection(ConnectionString);
        await connection.OpenAsync();
        return connection;
    }

    /// <summary>Queues a new invoice the way the API does (Bekliyor, with its outbox entry); returns its number.</summary>
    protected async Task<string> CreateInvoiceAsync()
    {
        await using var scope = NewScope();
        var created = await scope.ServiceProvider.GetRequiredService<CreateInvoiceHandler>().HandleAsync(
            new CreateInvoiceRequest("C1", 10m, "TRY", new DateOnly(2026, 10, 9)));
        return created.Invoice!.InvoiceNumber;
    }

    /// <summary>Takes the invoice's outbox entry and sends it to the fake ERP, as a worker would: the invoice is Gönderildi
    /// afterwards.</summary>
    protected async Task SendToErpAsync(string workerId = "worker")
    {
        await using var scope = NewScope();
        var processor = scope.ServiceProvider.GetRequiredService<OutboxProcessor>();
        foreach (var entry in await processor.ClaimAsync(10, workerId, CancellationToken.None))
            await processor.SendAsync(entry, workerId);
    }

    /// <summary>Sends every queued invoice, as the workers would, until none is waiting any more.</summary>
    protected async Task SendAllAsync()
    {
        for (var round = 0; await ScalarAsync<long>("SELECT count(*) FROM erp_outbox WHERE status = 'Bekliyor'") > 0; round++)
        {
            if (round == 100)
                throw new TimeoutException("Invoices are still queued after 100 rounds of sending.");
            await SendToErpAsync();
        }
    }

    /// <summary>Starts a reconciliation run (so findings have a run to belong to) and lets its lock go; returns its id.</summary>
    protected async Task<long> StartRunAsync()
    {
        await using var scope = NewScope();
        var started = await scope.ServiceProvider.GetRequiredService<ReconciliationService>()
            .TryStartAsync(operatorName: null, CancellationToken.None);
        await started!.Lease.DisposeAsync();
        return started.Run.Id;
    }

    /// <summary>Writes one planned fix of a reconciliation run, in a service copy of its own.</summary>
    protected async Task<bool> ApplyFixAsync(long runId, PlannedFinding finding)
    {
        await using var scope = NewScope();
        return await scope.ServiceProvider.GetRequiredService<FixApplier>().ApplyAsync(runId, finding);
    }

    protected async Task ExecuteAsync(string sql)
    {
        await using var connection = await OpenConnectionAsync();
        await using var command = new NpgsqlCommand(sql, connection);
        await command.ExecuteNonQueryAsync();
    }

    /// <summary>An ERP event about the invoice, with the reference the fake ERP gives it.</summary>
    protected static ErpWebhookRequest ErpEvent(string eventId, string eventType, string invoiceNumber) =>
        new(eventId, eventType, invoiceNumber, $"ERP-{invoiceNumber}", DateTimeOffset.UtcNow, eventType == WebhookEventType.Rejected ? "reason" : null);

    /// <summary>One delivery of the event, in a service copy of its own.</summary>
    protected async Task<EventResult> DeliverAsync(ErpWebhookRequest request)
    {
        await using var scope = NewScope();
        return await scope.ServiceProvider.GetRequiredService<WebhookEventProcessor>().ReceiveAsync(
            request, JsonSerializer.Serialize(request, JsonSerializerOptions.Web), CancellationToken.None);
    }

    protected async Task<T?> ScalarAsync<T>(string sql, params (string Name, object Value)[] parameters)
    {
        await using var connection = await OpenConnectionAsync();
        await using var command = new NpgsqlCommand(sql, connection);
        foreach (var (name, value) in parameters)
            command.Parameters.AddWithValue(name, value);
        var result = await command.ExecuteScalarAsync();
        return result is null or DBNull ? default : (T)result;
    }
}
