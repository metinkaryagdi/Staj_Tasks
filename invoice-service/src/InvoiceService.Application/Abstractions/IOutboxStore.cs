using InvoiceService.Application.Outbox;

namespace InvoiceService.Application.Abstractions;

/// <summary>Storage of the queued ERP sends (the erp_outbox table).</summary>
public interface IOutboxStore
{
    /// <summary>
    /// Takes up to <paramref name="limit"/> due entries that nobody holds (two instances never get the same row) and counts
    /// the attempt before it is made.
    /// </summary>
    Task<IReadOnlyList<ClaimedEntry>> ClaimAsync(
        int limit, string workerId, DateTimeOffset now, DateTimeOffset lockedUntil, int maxAttempts, CancellationToken ct);

    /// <summary>Whether the entry still carries this claim and its lock has not run out.</summary>
    Task<bool> IsHeldAsync(long id, Guid claimToken, DateTimeOffset now, CancellationToken ct);

    /// <summary>
    /// Writes the outcome, only if the entry is still Bekliyor and still carries this claim (and clears the lock and the
    /// claim). Returns false when it does not: the entry was taken again, so this older outcome is dropped.
    /// </summary>
    Task<bool> WriteOutcomeAsync(
        long id, Guid claimToken, string status, string? lastError, DateTimeOffset nextAttemptAt, DateTimeOffset? processedAt,
        CancellationToken ct);

    /// <summary>
    /// Resets the invoice's entry so the worker treats it like a new one (Bekliyor, 0 attempts, due now), inserting it if
    /// it is missing.
    /// </summary>
    Task ResetAsync(string invoiceNumber, DateTimeOffset now, CancellationToken ct);
}
