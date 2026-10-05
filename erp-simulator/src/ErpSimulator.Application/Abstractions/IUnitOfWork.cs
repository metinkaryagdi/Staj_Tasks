namespace ErpSimulator.Application.Abstractions;

/// <summary>The transaction boundary of one DI scope: every store in the scope takes part in the open
/// transaction.</summary>
public interface IUnitOfWork
{
    /// <summary>
    /// Starts a transaction. Disposing it without <see cref="IUnitOfWorkTransaction.CommitAsync"/> rolls it back.
    /// </summary>
    Task<IUnitOfWorkTransaction> BeginAsync(CancellationToken ct);
}

public interface IUnitOfWorkTransaction : IAsyncDisposable
{
    Task CommitAsync(CancellationToken ct);
}
