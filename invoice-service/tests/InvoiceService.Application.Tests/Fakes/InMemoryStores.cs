using InvoiceService.Application.Abstractions;
using InvoiceService.Application.Outbox;
using InvoiceService.Application.Webhooks;
using InvoiceService.Domain.Invoices;
using InvoiceService.Domain.Outbox;
using InvoiceService.Domain.Webhooks;

namespace InvoiceService.Application.Tests.Fakes;

/// <summary>A fixed clock.</summary>
public sealed class FixedTime(DateTimeOffset now) : TimeProvider
{
    public DateTimeOffset Now { get; set; } = now;

    public override DateTimeOffset GetUtcNow() => Now;
}

/// <summary>Records the transactions; SaveChanges is a no-op because the stores hand out the objects they keep.</summary>
public sealed class FakeUnitOfWork : IUnitOfWork
{
    public int Begun { get; private set; }
    public int Committed { get; private set; }
    public int Saves { get; private set; }

    public Task<IUnitOfWorkTransaction> BeginAsync(CancellationToken ct)
    {
        Begun++;
        return Task.FromResult<IUnitOfWorkTransaction>(new Transaction(this));
    }

    public Task SaveChangesAsync(CancellationToken ct)
    {
        Saves++;
        return Task.CompletedTask;
    }

    private sealed class Transaction(FakeUnitOfWork owner) : IUnitOfWorkTransaction
    {
        public Task CommitAsync(CancellationToken ct)
        {
            owner.Committed++;
            return Task.CompletedTask;
        }

        public ValueTask DisposeAsync() => ValueTask.CompletedTask;
    }
}

public sealed class FakeInvoiceStore : IInvoiceStore
{
    public Dictionary<string, Invoice> Invoices { get; } = [];
    public List<(Invoice Invoice, ErpOutboxEntry Entry)> Queued { get; } = [];

    public Invoice Add(string number, string status, int sendAttempts = 1, string? erpReference = null)
    {
        var invoice = new Invoice
        {
            InvoiceNumber = number, CustomerCode = "C-001", Amount = 10.50m, Currency = "TRY",
            InvoiceDate = new DateOnly(2026, 10, 1), Status = status, ErpReference = erpReference,
            SendAttemptCount = sendAttempts
        };
        Invoices[number] = invoice;
        return invoice;
    }

    public Task<string> NextInvoiceNumberAsync(CancellationToken ct) =>
        Task.FromResult(InvoiceNumber.Format(Invoices.Count + 1));

    public Task QueueAsync(Invoice invoice, ErpOutboxEntry entry, CancellationToken ct)
    {
        Invoices[invoice.InvoiceNumber] = invoice;
        Queued.Add((invoice, entry));
        return Task.CompletedTask;
    }

    public Task<Invoice?> FindAsync(string invoiceNumber, CancellationToken ct) =>
        Task.FromResult(Invoices.GetValueOrDefault(invoiceNumber));

    public Task<Invoice> GetAsync(string invoiceNumber, CancellationToken ct) => Task.FromResult(Invoices[invoiceNumber]);

    public Task<IReadOnlyList<Invoice>> ListAsync(string? status, CancellationToken ct) =>
        Task.FromResult<IReadOnlyList<Invoice>>(
            Invoices.Values.Where(i => status is null || i.Status == status).OrderBy(i => i.InvoiceNumber).ToList());

    public Task<int> MarkPendingIfFailedAsync(string invoiceNumber, DateTimeOffset now, CancellationToken ct)
    {
        if (!Invoices.TryGetValue(invoiceNumber, out var i) || i.Status != InvoiceStatus.Failed)
            return Task.FromResult(0);
        i.Status = InvoiceStatus.Pending;
        i.LastError = null;
        i.UpdatedAt = now;
        return Task.FromResult(1);
    }

    public Task WriteSendOutcomeAsync(
        string invoiceNumber, string status, string? erpReference, string? lastError, DateTimeOffset now, CancellationToken ct)
    {
        var i = Invoices[invoiceNumber];
        i.Status = status;
        i.ErpReference = erpReference;
        i.LastError = lastError;
        i.UpdatedAt = now;
        return Task.CompletedTask;
    }

    public Task<Invoice?> LockAsync(string invoiceNumber, CancellationToken ct) =>
        Task.FromResult(Invoices.GetValueOrDefault(invoiceNumber));
}

public sealed class FakeOutboxStore : IOutboxStore
{
    /// <summary>What <see cref="IsHeldAsync"/> answers.</summary>
    public bool Held { get; set; } = true;

    /// <summary>What <see cref="WriteOutcomeAsync"/> answers (false: the entry was taken again meanwhile).</summary>
    public bool Owned { get; set; } = true;

    public List<(long Id, string Status, string? Error, DateTimeOffset NextAttemptAt, DateTimeOffset? ProcessedAt)> Outcomes { get; } = [];
    public List<string> Resets { get; } = [];
    public List<string> Completed { get; } = [];

    public Task CompleteFailedAsync(string invoiceNumber, DateTimeOffset now, CancellationToken ct)
    {
        Completed.Add(invoiceNumber);
        return Task.CompletedTask;
    }

    public Task<IReadOnlyList<ClaimedEntry>> ClaimAsync(
        int limit, string workerId, DateTimeOffset now, DateTimeOffset lockedUntil, int maxAttempts, CancellationToken ct) =>
        Task.FromResult<IReadOnlyList<ClaimedEntry>>([]);

    public Task<bool> IsHeldAsync(long id, Guid claimToken, DateTimeOffset now, CancellationToken ct) => Task.FromResult(Held);

    public Task<bool> WriteOutcomeAsync(
        long id, Guid claimToken, string status, string? lastError, DateTimeOffset nextAttemptAt, DateTimeOffset? processedAt,
        CancellationToken ct)
    {
        if (Owned)
            Outcomes.Add((id, status, lastError, nextAttemptAt, processedAt));
        return Task.FromResult(Owned);
    }

    public Task ResetAsync(string invoiceNumber, DateTimeOffset now, CancellationToken ct)
    {
        Resets.Add(invoiceNumber);
        return Task.CompletedTask;
    }
}

public sealed class FakeWebhookEventStore : IWebhookEventStore
{
    public Dictionary<string, ErpWebhookEvent> Events { get; } = [];

    public Task LimitWaitsAsync(int lockTimeoutMilliseconds, int statementTimeoutMilliseconds, CancellationToken ct) =>
        Task.CompletedTask;

    public Task<bool> InsertOrCountAsync(ErpWebhookRequest request, string payload, DateTimeOffset now, CancellationToken ct)
    {
        if (Events.TryGetValue(request.EventId!, out var stored))
        {
            stored.DeliveryCount++;
            return Task.FromResult(false);
        }
        Events[request.EventId!] = new ErpWebhookEvent
        {
            EventId = request.EventId!, EventType = request.EventType!, InvoiceNumber = request.InvoiceNumber!,
            ErpReference = request.ErpReference!, OccurredAt = request.OccurredAt!.Value, ReceivedAt = now,
            Status = WebhookEventStatus.Pending, Payload = payload
        };
        return Task.FromResult(true);
    }

    /// <summary>What <see cref="IgnoreUnknownInvoiceAsync"/> treats as the invoices the service has.</summary>
    public HashSet<string> KnownInvoices { get; } = [];

    public Task<bool> IgnoreUnknownInvoiceAsync(string eventId, CancellationToken ct)
    {
        if (!Events.TryGetValue(eventId, out var e) || e.Status != WebhookEventStatus.Pending || KnownInvoices.Contains(e.InvoiceNumber))
            return Task.FromResult(false);
        e.Status = WebhookEventStatus.Ignored;
        e.IgnoreReason = IgnoreReason.UnknownInvoice;
        return Task.FromResult(true);
    }

    public Task<ErpWebhookEvent> GetAsync(string eventId, CancellationToken ct) => Task.FromResult(Events[eventId]);

    public Task<ErpWebhookEvent> GetTrackedAsync(string eventId, CancellationToken ct) => Task.FromResult(Events[eventId]);

    public Task<IReadOnlyList<ErpWebhookEvent>> LockWaitingAsync(string invoiceNumber, CancellationToken ct) =>
        Task.FromResult<IReadOnlyList<ErpWebhookEvent>>(Events.Values
            .Where(e => e.InvoiceNumber == invoiceNumber && e.Status == WebhookEventStatus.Pending)
            .OrderBy(e => e.ReceivedAt).ThenBy(e => e.OccurredAt).ToList());
}

/// <summary>Answers from queues set up by the test and records every call.</summary>
public sealed class FakeErpGateway : IErpGateway
{
    public Queue<ErpSendResult> SendResults { get; } = new();
    public Queue<ErpLookupResult> LookupResults { get; } = new();
    public List<string> Calls { get; } = [];
    public ErpListResult ListResult { get; set; } = new(true, [], null);

    public Task<ErpListResult> ListAsync(DateTimeOffset from, DateTimeOffset to, CancellationToken ct)
    {
        Calls.Add("LIST");
        return Task.FromResult(ListResult);
    }

    public Task<ErpSendResult> SendAsync(Invoice invoice, CancellationToken ct)
    {
        Calls.Add($"POST {invoice.InvoiceNumber}");
        return Task.FromResult(SendResults.Dequeue());
    }

    public Task<ErpLookupResult> FindAsync(string invoiceNumber, CancellationToken ct)
    {
        Calls.Add($"GET {invoiceNumber}");
        return Task.FromResult(LookupResults.Dequeue());
    }

    public static ErpSendResult Accepted(string reference) => new(true, reference, 202, null, TimeSpan.Zero);
    public static ErpSendResult ServerError() => new(false, null, 500, "ERP 500", TimeSpan.Zero);
    public static ErpLookupResult Found(string reference) => new(ErpLookup.Found, reference, 200, null, TimeSpan.Zero);
    public static ErpLookupResult NotFound() => new(ErpLookup.NotFound, null, 404, null, TimeSpan.Zero);
    public static ErpLookupResult Unknown() => new(ErpLookup.Unknown, null, null, "ERP'ye ulaşılamadı", TimeSpan.Zero);
}
