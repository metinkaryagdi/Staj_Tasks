namespace InvoiceService.Application.Abstractions;

/// <summary>
/// The lock that lets only one reconciliation run at a time, across every copy of the service. It does not depend on a
/// row that a stopped copy could leave behind: it is released when its holder lets go or its connection ends.
/// </summary>
public interface IReconciliationLock
{
    /// <summary>The lock, held until the result is disposed; null when somebody else (this copy or another) holds
    /// it.</summary>
    Task<IAsyncDisposable?> TryAcquireAsync(CancellationToken ct);
}
