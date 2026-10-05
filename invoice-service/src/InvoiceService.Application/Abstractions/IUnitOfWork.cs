namespace InvoiceService.Application.Abstractions;

/// <summary>
/// The transaction boundary of one DI scope. Every store in the scope takes part in the open transaction, and entities
/// a store returns as "tracked" are written by <see cref="SaveChangesAsync"/>.
/// </summary>
public interface IUnitOfWork
{
    /// <summary>
    /// Starts a transaction. Disposing it without <see cref="IUnitOfWorkTransaction.CommitAsync"/> rolls it back.
    /// </summary>
    Task<IUnitOfWorkTransaction> BeginAsync(CancellationToken ct);

    /// <summary>Writes the changes made to tracked entities.</summary>
    Task SaveChangesAsync(CancellationToken ct);
}

public interface IUnitOfWorkTransaction : IAsyncDisposable
{
    Task CommitAsync(CancellationToken ct);
}
