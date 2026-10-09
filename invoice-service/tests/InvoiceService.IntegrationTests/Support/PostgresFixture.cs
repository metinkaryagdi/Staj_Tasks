using InvoiceService.Application;
using InvoiceService.Infrastructure;
using InvoiceService.Infrastructure.Persistence;
using Microsoft.EntityFrameworkCore;
using Microsoft.Extensions.DependencyInjection;
using Npgsql;
using Testcontainers.PostgreSql;

namespace InvoiceService.IntegrationTests.Support;

/// <summary>
/// One PostgreSQL container for all tests, started once. The migrations are applied to a template database; every test
/// gets its own copy of it, so tests never see each other's data and nothing needs cleaning up between them.
/// </summary>
public sealed class PostgresFixture : IAsyncLifetime
{
    private const string TemplateName = "invoice_template";

    private readonly PostgreSqlContainer _container = new PostgreSqlBuilder("postgres:17-alpine").Build();
    private int _databases;

    public async Task InitializeAsync()
    {
        await _container.StartAsync();
        await ExecuteAsync($"CREATE DATABASE {TemplateName}");

        var services = new ServiceCollection();
        services.AddLogging();
        services.AddInvoiceInfrastructure(TestSettings.Build(ConnectionStringOf(TemplateName), "http://localhost:1"));
        await using var provider = services.BuildServiceProvider();
        await using var scope = provider.CreateAsyncScope();
        await scope.ServiceProvider.GetRequiredService<InvoiceDbContext>().Database.MigrateAsync();

        // A database cannot be copied while a connection to it is open.
        NpgsqlConnection.ClearAllPools();
    }

    public async Task DisposeAsync() => await _container.DisposeAsync();

    /// <summary>A new database with the migrated schema and no rows; returns its connection string.</summary>
    public async Task<(string Name, string ConnectionString)> CreateDatabaseAsync()
    {
        var name = $"test_{Interlocked.Increment(ref _databases)}_{Guid.NewGuid():N}";
        await ExecuteAsync($"CREATE DATABASE {name} TEMPLATE {TemplateName}");
        return (name, ConnectionStringOf(name));
    }

    public async Task DropDatabaseAsync(string name)
    {
        NpgsqlConnection.ClearAllPools();
        await ExecuteAsync($"DROP DATABASE IF EXISTS {name} WITH (FORCE)");
    }

    private string ConnectionStringOf(string database) =>
        new NpgsqlConnectionStringBuilder(_container.GetConnectionString()) { Database = database }.ConnectionString;

    private async Task ExecuteAsync(string sql)
    {
        await using var connection = new NpgsqlConnection(_container.GetConnectionString());
        await connection.OpenAsync();
        await using var command = new NpgsqlCommand(sql, connection);
        await command.ExecuteNonQueryAsync();
    }
}

[CollectionDefinition(Name)]
public sealed class DatabaseCollection : ICollectionFixture<PostgresFixture>
{
    public const string Name = "Database";
}
