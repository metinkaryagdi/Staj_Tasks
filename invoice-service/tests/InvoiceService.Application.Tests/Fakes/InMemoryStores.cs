using InvoiceService.Application.Abstractions;
using InvoiceService.Application.Invoices;
using Microsoft.Extensions.DependencyInjection;
using InvoiceService.Application.Outbox;
using InvoiceService.Application.Reconciliation;
using InvoiceService.Application.Webhooks;
using InvoiceService.Domain.Invoices;
using InvoiceService.Domain.Operators;
using InvoiceService.Domain.Outbox;
using InvoiceService.Domain.Reconciliation;
using InvoiceService.Domain.Webhooks;

namespace InvoiceService.Application.Tests.Fakes;

/// <summary>A fixed clock.</summary>
public sealed class FixedTime(DateTimeOffset now) : TimeProvider
{
    public DateTimeOffset Now { get; set; } = now;

    public override DateTimeOffset GetUtcNow() => Now;
}

/// <summary>Records the transactions; SaveChanges is a no-op because the stores hand out the objects they
/// keep.</summary>
/// <summary>A clock that moves on by a step every time it is read.</summary>
public sealed class SteppingTime(DateTimeOffset start, TimeSpan step) : TimeProvider
{
    private DateTimeOffset _now = start;

    public override DateTimeOffset GetUtcNow()
    {
        var current = _now;
        _now += step;
        return current;
    }
}

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

    public Task<InvoicePage> ListPageAsync(
        string? status, string? search, DateTimeOffset? stuckBefore, int skip, int take, CancellationToken ct)
    {
        var matching = Invoices.Values
            .Where(i => (status is null || i.Status == status)
                        && (search is null || i.InvoiceNumber.Contains(search, StringComparison.OrdinalIgnoreCase))
                        && (stuckBefore is null || IsStuck(i, stuckBefore.Value)))
            .OrderByDescending(i => i.CreatedAt).ThenByDescending(i => i.InvoiceNumber)
            .ToList();
        return Task.FromResult(new InvoicePage(matching.Skip(skip).Take(take).ToList(), matching.Count));
    }

    public Task<IReadOnlyDictionary<string, int>> CountByStatusAsync(CancellationToken ct) =>
        Task.FromResult<IReadOnlyDictionary<string, int>>(
            Invoices.Values.GroupBy(i => i.Status).ToDictionary(g => g.Key, g => g.Count()));

    public Task<int> CountStuckAsync(DateTimeOffset olderThan, CancellationToken ct) =>
        Task.FromResult(Invoices.Values.Count(i => IsStuck(i, olderThan)));

    private static bool IsStuck(Invoice i, DateTimeOffset olderThan) =>
        i.Status is InvoiceStatus.Sent or InvoiceStatus.Processing && i.UpdatedAt < olderThan;

    /// <summary>Invoices whose resend fails, like a database that is gone for that moment.</summary>
    public HashSet<string> FailResend { get; } = [];

    public Task<int> MarkPendingIfFailedAsync(string invoiceNumber, DateTimeOffset now, CancellationToken ct)
    {
        if (FailResend.Contains(invoiceNumber))
            throw new InvalidOperationException("connection lost");
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

    /// <summary>Invoices whose lock fails, like a transaction chosen as the deadlock victim.</summary>
    public HashSet<string> FailLock { get; } = [];

    public Task<Invoice?> LockAsync(string invoiceNumber, CancellationToken ct) =>
        FailLock.Contains(invoiceNumber)
            ? throw new InvalidOperationException("deadlock detected")
            : Task.FromResult(Invoices.GetValueOrDefault(invoiceNumber));
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

    /// <summary>The entries <see cref="FindAsync"/> knows, by invoice number.</summary>
    public Dictionary<string, ErpOutboxEntry> Entries { get; } = [];

    public Task<ErpOutboxEntry?> FindAsync(string invoiceNumber, CancellationToken ct) =>
        Task.FromResult(Entries.GetValueOrDefault(invoiceNumber));

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

    public Task<IReadOnlyList<ErpWebhookEvent>> ListByInvoiceAsync(string invoiceNumber, CancellationToken ct) =>
        Task.FromResult<IReadOnlyList<ErpWebhookEvent>>(Events.Values
            .Where(e => e.InvoiceNumber == invoiceNumber).OrderBy(e => e.ReceivedAt).ThenBy(e => e.OccurredAt).ToList());

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
    public (DateTimeOffset From, DateTimeOffset To)? LastListRange { get; private set; }

    /// <summary>Called with the invoice number each time the ERP is asked about an invoice.</summary>
    public Action<string>? OnFind { get; set; }

    public Task<ErpListResult> ListAsync(DateTimeOffset from, DateTimeOffset to, CancellationToken ct)
    {
        Calls.Add("LIST");
        LastListRange = (from, to);
        return Task.FromResult(ListResult.Succeeded
            ? ListResult with { Records = ListResult.Records.Where(r => r.ReceivedAt >= from && r.ReceivedAt < to).ToList() }
            : ListResult);
    }

    public Task<ErpSendResult> SendAsync(Invoice invoice, CancellationToken ct)
    {
        Calls.Add($"POST {invoice.InvoiceNumber}");
        return Task.FromResult(SendResults.Dequeue());
    }

    public Task<ErpLookupResult> FindAsync(string invoiceNumber, CancellationToken ct)
    {
        Calls.Add($"GET {invoiceNumber}");
        OnFind?.Invoke(invoiceNumber);
        return Task.FromResult(LookupResults.Dequeue());
    }

    public static ErpSendResult Accepted(string reference) => new(true, reference, 202, null, TimeSpan.Zero);
    public static ErpSendResult ServerError() => new(false, null, 500, "ERP 500", TimeSpan.Zero);
    public static ErpLookupResult Found(string reference) => new(ErpLookup.Found, reference, 200, null, TimeSpan.Zero);

    /// <summary>The ERP has the invoice: its records and its decision, as a lookup answer carries them.</summary>
    public static ErpLookupResult FoundWith(ErpDecision decision, params ErpRecord[] records) =>
        new(ErpLookup.Found, records[0].ErpReference, 200, null, TimeSpan.Zero, decision, records);

    public static ErpLookupResult NotFound() => new(ErpLookup.NotFound, null, 404, null, TimeSpan.Zero);
    public static ErpLookupResult Unknown() => new(ErpLookup.Unknown, null, null, "ERP'ye ulaşılamadı", TimeSpan.Zero);
}


public sealed class FakeReconciliationStore(FakeInvoiceStore invoices, FakeWebhookEventStore events) : IReconciliationStore
{
    public List<ReconciliationRun> Runs { get; } = [];
    public List<ReconciliationFinding> Findings { get; } = [];
    public bool FailToStart { get; set; }

    /// <summary>Findings this says yes to cannot be recorded, like a database that refuses them.</summary>
    public Func<ReconciliationFinding, bool>? RefuseFinding { get; set; }

    public Task<ReconciliationRun> StartRunAsync(DateTimeOffset now, string startedBy, CancellationToken ct)
    {
        if (FailToStart)
            throw new InvalidOperationException("database is gone");
        var run = new ReconciliationRun
        {
            Id = Runs.Count + 1, StartedAt = now, Status = ReconciliationStatus.Running, StartedBy = startedBy
        };
        Runs.Add(run);
        return Task.FromResult(run);
    }

    public Task<int> FailAbandonedRunsAsync(DateTimeOffset now, CancellationToken ct)
    {
        var abandoned = Runs.Where(r => r.Status == ReconciliationStatus.Running).ToList();
        foreach (var run in abandoned)
        {
            run.Status = ReconciliationStatus.Failed;
            run.FinishedAt = now;
            run.Error = "Servis durdu: çalışma sonuçlanmadan kesildi.";
        }
        return Task.FromResult(abandoned.Count);
    }

    public Task FinishRunAsync(
        long id, string status, int checkedCount, int fixedCount, int reportedCount, string? error, DateTimeOffset now,
        CancellationToken ct)
    {
        var run = Runs.Single(r => r.Id == id);
        run.Status = status;
        run.FinishedAt = now;
        run.CheckedCount = checkedCount;
        run.FixedCount = fixedCount;
        run.ReportedCount = reportedCount;
        run.Error = error;
        return Task.CompletedTask;
    }

    public void AddFinding(ReconciliationFinding finding)
    {
        if (RefuseFinding?.Invoke(finding) == true)
            throw new InvalidOperationException("finding refused");
        finding.Id = Findings.Count + 1;
        Findings.Add(finding);
    }

    public Task<IReadOnlyList<ReconciliationRun>> ListRunsAsync(CancellationToken ct) =>
        Task.FromResult<IReadOnlyList<ReconciliationRun>>(Runs.OrderByDescending(r => r.Id).ToList());

    public Task<ReconciliationRun?> FindRunAsync(long id, CancellationToken ct) =>
        Task.FromResult(Runs.SingleOrDefault(r => r.Id == id));

    public Task<IReadOnlyList<ReconciliationFinding>> ListFindingsAsync(long runId, CancellationToken ct) =>
        Task.FromResult<IReadOnlyList<ReconciliationFinding>>(Findings.Where(f => f.RunId == runId).ToList());

    public Task<IReadOnlyList<ReconciliationFinding>> ListFindingsOfInvoiceAsync(string invoiceNumber, CancellationToken ct) =>
        Task.FromResult<IReadOnlyList<ReconciliationFinding>>(
            Findings.Where(f => f.InvoiceNumber == invoiceNumber).OrderByDescending(f => f.Id).ToList());

    public Task<IReadOnlyList<Invoice>> InvoicesToCheckAsync(DateTimeOffset since, CancellationToken ct) =>
        Task.FromResult<IReadOnlyList<Invoice>>(invoices.Invoices.Values
            .Where(i => i.CreatedAt >= since || InvoiceStatus.Unsettled.Contains(i.Status)).ToList());

    public Task<IReadOnlyList<Invoice>> InvoicesByNumberAsync(IReadOnlyCollection<string> numbers, CancellationToken ct) =>
        Task.FromResult<IReadOnlyList<Invoice>>(invoices.Invoices.Values.Where(i => numbers.Contains(i.InvoiceNumber)).ToList());

    public Task RecordErpChecksAsync(IReadOnlyList<ErpCheck> checks, DateTimeOffset at, CancellationToken ct)
    {
        foreach (var check in checks)
        {
            if (invoices.Invoices.TryGetValue(check.InvoiceNumber, out var invoice))
            {
                invoice.ErpCheckedAt = at;
                invoice.ErpCheckResult = check.Result;
            }
        }
        return Task.CompletedTask;
    }

    public Task<IReadOnlyList<ErpWebhookEvent>> WaitingEventsOfUnknownInvoicesAsync(CancellationToken ct) =>
        Task.FromResult<IReadOnlyList<ErpWebhookEvent>>(events.Events.Values
            .Where(e => e.Status == WebhookEventStatus.Pending && !invoices.Invoices.ContainsKey(e.InvoiceNumber)).ToList());
}

/// <summary>Held or free as the test says; counts how often it was taken and let go.</summary>
public sealed class FakeReconciliationLock : IReconciliationLock
{
    public bool HeldByOthers { get; set; }
    public int Acquired { get; private set; }
    public int Released { get; private set; }

    public Task<IAsyncDisposable?> TryAcquireAsync(CancellationToken ct)
    {
        if (HeldByOthers)
            return Task.FromResult<IAsyncDisposable?>(null);
        Acquired++;
        return Task.FromResult<IAsyncDisposable?>(new Lease(this));
    }

    private sealed class Lease(FakeReconciliationLock owner) : IAsyncDisposable
    {
        public ValueTask DisposeAsync()
        {
            owner.Released++;
            return ValueTask.CompletedTask;
        }
    }
}

/// <summary>Hands out what the test registers, a new scope each time, like the DI container does for scoped
/// services.</summary>
public sealed class FakeScopeFactory(Func<Type, object?> resolve) : IServiceScopeFactory
{
    public int Created { get; private set; }

    public IServiceScope CreateScope()
    {
        Created++;
        return new Scope(resolve);
    }

    private sealed class Scope(Func<Type, object?> resolve) : IServiceScope, IServiceProvider
    {
        public IServiceProvider ServiceProvider => this;

        public object? GetService(Type serviceType) => resolve(serviceType);

        public void Dispose()
        {
        }
    }
}

public sealed class FakeOperatorActionStore : IOperatorActionStore
{
    public List<OperatorAction> Actions { get; } = [];

    /// <summary>Records for these invoices fail, like a database that is gone for that moment.</summary>
    public HashSet<string> Refuse { get; } = [];

    public Task RecordAsync(OperatorAction action, CancellationToken ct)
    {
        if (action.InvoiceNumber is not null && Refuse.Contains(action.InvoiceNumber))
            throw new InvalidOperationException("connection lost");
        action.Id = Actions.Count + 1;
        Actions.Add(action);
        return Task.CompletedTask;
    }

    public Task<IReadOnlyList<OperatorAction>> ListOfInvoiceAsync(string invoiceNumber, CancellationToken ct) =>
        Task.FromResult<IReadOnlyList<OperatorAction>>(
            Actions.Where(a => a.InvoiceNumber == invoiceNumber).OrderByDescending(a => a.Id).ToList());
}
