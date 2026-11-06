using InvoiceService.Api.Startup;
using InvoiceService.Application;
using InvoiceService.Application.Abstractions;
using InvoiceService.Infrastructure;
using InvoiceService.Infrastructure.Persistence;
using InvoiceService.IntegrationTests.Support;
using Microsoft.Extensions.Configuration;
using Microsoft.Extensions.DependencyInjection;
using Microsoft.Extensions.Logging.Abstractions;
using Npgsql;

namespace InvoiceService.IntegrationTests;

/// <summary>
/// The other tests connect as the database's owner, so a missing grant only shows with the application's own user: the
/// tables it writes are tried here as that user.
/// </summary>
public class AppUserGrantTests(PostgresFixture postgres) : IntegrationTest(postgres)
{
    private const string User = "invoice_app_test";
    private const string Password = "test-only-password";

    private async Task<string> GrantAndGetAppConnectionAsync()
    {
        var configuration = new ConfigurationBuilder().AddInMemoryCollection(new Dictionary<string, string?>
        {
            ["AppDatabaseUser:Name"] = User,
            ["AppDatabaseUser:Password"] = Password
        }).Build();
        await using var scope = NewScope();
        await DatabaseMigrator.GrantAppUserAsync(
            scope.ServiceProvider.GetRequiredService<InvoiceDbContext>(), configuration, NullLogger.Instance);
        return new NpgsqlConnectionStringBuilder(ConnectionString) { Username = User, Password = Password }.ConnectionString;
    }

    [Fact]
    public async Task The_application_user_can_change_the_erp_version_share()
    {
        var connection = await GrantAndGetAppConnectionAsync();
        var configuration = TestSettings.Build(connection, Erp.BaseUrl);
        var services = new ServiceCollection();
        services.AddLogging();
        services.AddSingleton(configuration);
        services.AddInvoiceApplication(configuration);
        services.AddInvoiceInfrastructure(configuration);
        await using var provider = services.BuildServiceProvider();
        var setting = provider.GetRequiredService<IErpVersionSetting>();

        await setting.SetV2PercentAsync(50, CancellationToken.None);

        Assert.Equal(50, await setting.GetV2PercentAsync(CancellationToken.None));
    }

    [Theory]
    [InlineData("UPDATE invoices SET status = status")]
    [InlineData("UPDATE erp_outbox SET status = status")]
    [InlineData("UPDATE erp_webhook_events SET status = status")]
    [InlineData("UPDATE invoice_follow_ups SET note = note")]
    [InlineData("UPDATE reconciliation_runs SET status = status")]
    [InlineData("UPDATE erp_send_pace SET next_turn_at = next_turn_at")]
    [InlineData("UPDATE erp_version_setting SET v2_percent = v2_percent")]
    public async Task The_application_user_can_update_the_tables_the_service_updates(string sql)
    {
        await using var connection = new NpgsqlConnection(await GrantAndGetAppConnectionAsync());
        await connection.OpenAsync();
        await using var command = new NpgsqlCommand(sql, connection);

        await command.ExecuteNonQueryAsync();
    }

    [Theory]
    [InlineData("UPDATE operator_actions SET action = action")]
    [InlineData("UPDATE reconciliation_findings SET details = details")]
    [InlineData("DELETE FROM erp_version_setting")]
    [InlineData("DROP TABLE erp_version_setting")]
    public async Task The_application_user_cannot_do_more(string sql)
    {
        await using var connection = new NpgsqlConnection(await GrantAndGetAppConnectionAsync());
        await connection.OpenAsync();
        await using var command = new NpgsqlCommand(sql, connection);

        var refused = await Assert.ThrowsAsync<PostgresException>(() => command.ExecuteNonQueryAsync());
        Assert.Equal("42501", refused.SqlState);
    }
}
