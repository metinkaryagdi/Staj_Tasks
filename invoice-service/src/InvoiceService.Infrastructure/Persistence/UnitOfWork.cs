using InvoiceService.Application.Abstractions;

namespace InvoiceService.Infrastructure.Persistence;

/// <summary>
/// The scope's DbContext as the transaction boundary: every store in the scope uses the same context, so what they do
/// while a transaction is open belongs to it.
/// </summary>
public sealed class UnitOfWork(InvoiceDbContext db) : IUnitOfWork
{
    public async Task<IUnitOfWorkTransaction> BeginAsync(CancellationToken ct) =>
        new Transaction(await db.Database.BeginTransactionAsync(ct));

    public Task SaveChangesAsync(CancellationToken ct) => db.SaveChangesAsync(ct);

    private sealed class Transaction(Microsoft.EntityFrameworkCore.Storage.IDbContextTransaction inner) : IUnitOfWorkTransaction
    {
        public Task CommitAsync(CancellationToken ct) => inner.CommitAsync(ct);

        public ValueTask DisposeAsync() => inner.DisposeAsync();
    }
}
