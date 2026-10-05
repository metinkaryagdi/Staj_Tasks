using ErpSimulator.Application.Abstractions;
using ErpSimulator.Domain.Invoices;
using ErpSimulator.Domain.Webhooks;

namespace ErpSimulator.Application.Tests.Fakes;

/// <summary>A fixed clock.</summary>
public sealed class FixedTime(DateTimeOffset now) : TimeProvider
{
    public DateTimeOffset Now { get; set; } = now;

    public override DateTimeOffset GetUtcNow() => Now;
}

public sealed class FakeUnitOfWork : IUnitOfWork
{
    public int Committed { get; private set; }

    public Task<IUnitOfWorkTransaction> BeginAsync(CancellationToken ct) =>
        Task.FromResult<IUnitOfWorkTransaction>(new Transaction(this));

    internal sealed class Transaction(FakeUnitOfWork owner) : IUnitOfWorkTransaction
    {
        public Task CommitAsync(CancellationToken ct)
        {
            owner.Committed++;
            return Task.CompletedTask;
        }

        public ValueTask DisposeAsync() => ValueTask.CompletedTask;
    }
}

/// <summary>Keeps the records in a list; references are given out in save order like the database's.</summary>
public sealed class FakeErpInvoiceStore : IErpInvoiceStore
{
    public List<ErpInvoice> Records { get; } = [];
    public List<WebhookDelivery> Deliveries { get; } = [];
    public List<string> Locked { get; } = [];

    public Task<IUnitOfWorkTransaction> LockInvoiceNumberAsync(string invoiceNumber)
    {
        Locked.Add(invoiceNumber);
        return Task.FromResult<IUnitOfWorkTransaction>(new FakeUnitOfWork.Transaction(new FakeUnitOfWork()));
    }

    public Task<ErpInvoice?> FindFirstAsync(string invoiceNumber) =>
        Task.FromResult(Records.FirstOrDefault(r => r.InvoiceNumber == invoiceNumber));

    public Task<IReadOnlyList<ErpInvoice>> ListAsync(string invoiceNumber, CancellationToken ct) =>
        Task.FromResult<IReadOnlyList<ErpInvoice>>(Records.Where(r => r.InvoiceNumber == invoiceNumber).ToList());

    public Task SaveAsync(ErpInvoice invoice, Func<ErpInvoice, IEnumerable<WebhookDelivery>> planEvents)
    {
        invoice.Id = Records.Count + 1;
        invoice.ErpReference = $"ERP-{invoice.Id:D8}";
        Records.Add(invoice);
        Deliveries.AddRange(planEvents(invoice));
        return Task.CompletedTask;
    }

    public Task<InvoicePage> ListReceivedAsync(DateTimeOffset from, DateTimeOffset to, int skip, int take, CancellationToken ct)
    {
        var range = Records.Where(r => r.ReceivedAt >= from && r.ReceivedAt < to).OrderBy(r => r.ReceivedAt).ThenBy(r => r.Id).ToList();
        return Task.FromResult(new InvoicePage(range.Skip(skip).Take(take).ToList(), range.Count));
    }
}

public sealed class FakeDeliveryStore : IWebhookDeliveryStore
{
    public bool StillPending { get; set; } = true;
    public List<(long Id, string Status, int Attempt, DateTimeOffset NextDue, int? Http, string? Error, DateTimeOffset? CompletedAt)> Recorded { get; } = [];
    public List<string> Released { get; } = [];
    public List<string> Skipped { get; } = [];
    public List<WebhookDelivery> Planned { get; } = [];

    public Task<IReadOnlyList<WebhookDelivery>> ListForInvoiceAsync(long invoiceId, CancellationToken ct) =>
        Task.FromResult<IReadOnlyList<WebhookDelivery>>(Planned.Where(d => d.InvoiceId == invoiceId).ToList());

    public Task<DateTimeOffset?> NextDueAtAsync(long[] busy, CancellationToken ct) => Task.FromResult<DateTimeOffset?>(null);

    public Task<IReadOnlyList<WebhookDelivery>> DueAsync(int limit, DateTimeOffset now, long[] busy, CancellationToken ct) =>
        Task.FromResult<IReadOnlyList<WebhookDelivery>>([]);

    public Task<bool> RecordSendAsync(
        long id, string status, int attempt, DateTimeOffset nextDue, int? httpStatus, string? error,
        DateTimeOffset? completedAt, DateTimeOffset sentAt)
    {
        if (StillPending)
            Recorded.Add((id, status, attempt, nextDue, httpStatus, error, completedAt));
        return Task.FromResult(StillPending);
    }

    public Task ReleaseReplaysAsync(string eventId, DateTimeOffset earliest)
    {
        Released.Add(eventId);
        return Task.CompletedTask;
    }

    public Task SkipReplaysAsync(string eventId)
    {
        Skipped.Add(eventId);
        return Task.CompletedTask;
    }
}

/// <summary>Answers with a fixed result and remembers what it was asked to send.</summary>
public sealed class FakeTransport : IWebhookTransport
{
    public WebhookPostResult Result { get; set; } = new(200, null);
    public bool ThrowStopping { get; set; }
    public List<(string Url, string Body, string Timestamp, string Signature)> Posts { get; } = [];

    public Task<WebhookPostResult> PostAsync(
        string url, byte[] body, string timestamp, string signature, TimeSpan timeout, CancellationToken stoppingToken)
    {
        Posts.Add((url, System.Text.Encoding.UTF8.GetString(body), timestamp, signature));
        if (ThrowStopping)
            throw new OperationCanceledException(stoppingToken);
        return Task.FromResult(Result);
    }
}
