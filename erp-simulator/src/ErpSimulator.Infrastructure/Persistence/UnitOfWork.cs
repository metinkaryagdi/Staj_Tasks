using ErpSimulator.Application.Abstractions;
using Microsoft.EntityFrameworkCore.Storage;

namespace ErpSimulator.Infrastructure.Persistence;

/// <summary>The scope's DbContext as the transaction boundary.</summary>
public sealed class UnitOfWork(ErpDbContext db) : IUnitOfWork
{
    public async Task<IUnitOfWorkTransaction> BeginAsync(CancellationToken ct) =>
        new Transaction(await db.Database.BeginTransactionAsync(ct));

    internal sealed class Transaction(IDbContextTransaction inner) : IUnitOfWorkTransaction
    {
        public Task CommitAsync(CancellationToken ct) => inner.CommitAsync(ct);

        public ValueTask DisposeAsync() => inner.DisposeAsync();
    }
}
