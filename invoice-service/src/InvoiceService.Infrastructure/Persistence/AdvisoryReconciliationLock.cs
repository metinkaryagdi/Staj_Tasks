using InvoiceService.Application.Abstractions;
using Npgsql;

namespace InvoiceService.Infrastructure.Persistence;

/// <summary>
/// A PostgreSQL advisory lock held on a connection of its own for as long as a run lasts. Every copy of the service uses
/// the same database and the same key, so only one of them can hold it. Pooling is off, so closing the connection ends the
/// session, and the database releases the lock: a copy that stops or crashes never leaves it held. The connection does
/// nothing else while a run lasts, so it is kept alive: an idle-timeout on the way to the database would end the session
/// and release the lock while the run goes on.
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
