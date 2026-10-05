using InvoiceService.Application.Abstractions;
using Npgsql;

namespace InvoiceService.Infrastructure.Persistence;

/// <summary>
/// A PostgreSQL advisory lock held on a connection of its own while a run lasts; every copy uses the same key, so
/// only one holds it. Pooling is off, so closing the connection releases it, and the idle connection is kept alive so
/// an idle-timeout cannot release it during a run. Why: ARCHITECTURE.md.
/// </summary>
public sealed class AdvisoryReconciliationLock(IConfiguration configuration) : IReconciliationLock
{
    /// <summary>Any number, as long as every copy uses the same one.</summary>
    private const long Key = 7_300_001;

    /// <summary>Seconds between the keepalive messages on the otherwise idle connection.</summary>
    private const int KeepAliveSeconds = 30;

    /// <summary>The configured connection string, for a connection that is not pooled and does not sit idle.</summary>
    public static string BuildConnectionString(string? configured) =>
        new NpgsqlConnectionStringBuilder(configured) { Pooling = false, KeepAlive = KeepAliveSeconds, TcpKeepAlive = true }
            .ConnectionString;

    public async Task<IAsyncDisposable?> TryAcquireAsync(CancellationToken ct)
    {
        var connection = new NpgsqlConnection(BuildConnectionString(configuration.GetConnectionString("InvoiceDb")));
        try
        {
            await connection.OpenAsync(ct);
            await using var command = new NpgsqlCommand("SELECT pg_try_advisory_lock(@key)", connection);
            command.Parameters.AddWithValue("key", Key);
            if ((bool)(await command.ExecuteScalarAsync(ct))!)
                return connection;

            await connection.DisposeAsync();
            return null;
        }
        catch
        {
            await connection.DisposeAsync();
            throw;
        }
    }
}
