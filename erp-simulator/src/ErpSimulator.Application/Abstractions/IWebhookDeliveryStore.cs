using ErpSimulator.Domain.Webhooks;

namespace ErpSimulator.Application.Abstractions;

/// <summary>Storage of the planned webhook sends (the webhook_deliveries table).</summary>
public interface IWebhookDeliveryStore
{
    /// <summary>The earliest due time of a Pending row that is not in <paramref name="busy"/>; null if there is none.</summary>
    Task<DateTimeOffset?> NextDueAtAsync(long[] busy, CancellationToken ct);

    /// <summary>Up to <paramref name="limit"/> Pending rows due by <paramref name="now"/>, not in <paramref name="busy"/>, oldest due first.</summary>
    Task<IReadOnlyList<WebhookDelivery>> DueAsync(int limit, DateTimeOffset now, long[] busy, CancellationToken ct);

    /// <summary>
    /// Writes the outcome of a send, only if the row is still Pending (first_sent_at is kept once set). Returns
    /// whether it was written.
    /// </summary>
    Task<bool> RecordSendAsync(
        long id, string status, int attempt, DateTimeOffset nextDue, int? httpStatus, string? error,
        DateTimeOffset? completedAt, DateTimeOffset sentAt);

    /// <summary>The event's waiting replays become Pending, due no earlier than <paramref name="earliest"/>.</summary>
    Task ReleaseReplaysAsync(string eventId, DateTimeOffset earliest);

    /// <summary>The event's waiting replays become Skipped: the event they repeat was never delivered.</summary>
    Task SkipReplaysAsync(string eventId);
}
