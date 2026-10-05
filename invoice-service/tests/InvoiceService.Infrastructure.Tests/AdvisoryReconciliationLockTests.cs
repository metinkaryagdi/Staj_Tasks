using InvoiceService.Infrastructure.Persistence;
using Npgsql;

namespace InvoiceService.Infrastructure.Tests;

public class AdvisoryReconciliationLockTests
{
    private const string Configured = "Host=invoice-db;Database=invoice_service;Username=invoice;Password=invoice";

    [Fact]
    public void The_lock_connection_is_not_pooled_and_is_kept_alive_while_it_sits_idle()
    {
        var built = new NpgsqlConnectionStringBuilder(AdvisoryReconciliationLock.BuildConnectionString(Configured));

        Assert.False(built.Pooling);
        Assert.True(built.KeepAlive > 0);
        Assert.True(built.TcpKeepAlive);
    }

    [Fact]
    public void The_lock_connection_goes_to_the_same_database_as_the_configured_one()
    {
        var built = new NpgsqlConnectionStringBuilder(AdvisoryReconciliationLock.BuildConnectionString(Configured));

        Assert.Equal("invoice-db", built.Host);
        Assert.Equal("invoice_service", built.Database);
        Assert.Equal("invoice", built.Username);
    }
}
