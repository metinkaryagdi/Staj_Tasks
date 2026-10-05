using ErpSimulator.Application.Abstractions;
using ErpSimulator.Domain.Webhooks;
using Microsoft.EntityFrameworkCore;

namespace ErpSimulator.Infrastructure.Persistence;

public sealed class WebhookDeliveryStore(ErpDbContext db) : IWebhookDeliveryStore
{
    public Task<DateTimeOffset?> NextDueAtAsync(long[] busy, CancellationToken ct) =>
        db.WebhookDeliveries.AsNoTracking()
            .Where(d => d.Status == DeliveryStatus.Pending && !busy.Contains(d.Id))
            .MinAsync(d => (DateTimeOffset?)d.DueAt, ct);

    public async Task<IReadOnlyList<WebhookDelivery>> DueAsync(int limit, DateTimeOffset now, long[] busy, CancellationToken ct) =>
        await db.WebhookDeliveries.AsNoTracking()
            .Where(d => d.Status == DeliveryStatus.Pending && d.DueAt <= now && !busy.Contains(d.Id))
            .OrderBy(d => d.DueAt).ThenBy(d => d.Id)
            .Take(limit)
            .ToListAsync(ct);

    public async Task<bool> RecordSendAsync(
        long id, string status, int attempt, DateTimeOffset nextDue, int? httpStatus, string? error,
        DateTimeOffset? completedAt, DateTimeOffset sentAt)
    {
        var updated = await db.WebhookDeliveries
            .Where(d => d.Id == id && d.Status == DeliveryStatus.Pending)
            .ExecuteUpdateAsync(s => s
                .SetProperty(d => d.Status, status)
                .SetProperty(d => d.AttemptCount, attempt)
                .SetProperty(d => d.DueAt, nextDue)
                .SetProperty(d => d.LastHttpStatus, httpStatus)
                .SetProperty(d => d.LastError, error)
                .SetProperty(d => d.CompletedAt, completedAt)
                .SetProperty(d => d.FirstSentAt, d => d.FirstSentAt ?? sentAt), CancellationToken.None);
        return updated != 0;
    }

    public Task ReleaseReplaysAsync(string eventId, DateTimeOffset earliest) =>
        WaitingReplays(eventId).ExecuteUpdateAsync(s => s
            .SetProperty(d => d.Status, DeliveryStatus.Pending)
            .SetProperty(d => d.DueAt, d => d.DueAt > earliest ? d.DueAt : earliest), CancellationToken.None);

    public Task SkipReplaysAsync(string eventId) =>
        WaitingReplays(eventId).ExecuteUpdateAsync(s => s
            .SetProperty(d => d.Status, DeliveryStatus.Skipped), CancellationToken.None);

    public async Task<IReadOnlyList<WebhookDelivery>> ListForInvoiceAsync(long invoiceId, CancellationToken ct) =>
        await db.WebhookDeliveries.AsNoTracking()
            .Where(d => d.InvoiceId == invoiceId && (d.Kind == DeliveryKind.Normal || d.Kind == DeliveryKind.LostDecision))
            .ToListAsync(ct);

    private IQueryable<WebhookDelivery> WaitingReplays(string eventId) =>
        db.WebhookDeliveries.Where(d => d.EventId == eventId
            && d.Kind == DeliveryKind.Replay && d.Status == DeliveryStatus.Waiting);
}
