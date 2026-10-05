using InvoiceService.Application.Abstractions;
using Npgsql;

namespace InvoiceService.Infrastructure.Persistence;

/// <summary>
/// A PostgreSQL advisory lock held on a connection of its own for as long as a run lasts. Every copy of the service uses
/// the same database and the same key, so only one of them can hold it. Pooling is off, so closing the connection ends the
/// session, and the database releases the lock: a copy that stops or crashes never leaves it held.
/// </summary>
public sealed class AdvisoryReconciliationLock(IConfiguration configuration) : IReconciliationLock
{
    /// <summary>Any number, as long as every copy uses the same one.</summary>
    private const long Key = 7_300_001;

    public async Task<IAsyncDisposable?> TryAcquireAsync(CancellationToken ct)
    {
        var connectionString = new NpgsqlConnectionStringBuilder(configuration.GetConnectionString("InvoiceDb")) { Pooling = false };
        var connection = new NpgsqlConnection(connectionString.ConnectionString);
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
