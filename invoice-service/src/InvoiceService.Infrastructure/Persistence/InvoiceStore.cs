using InvoiceService.Application.Abstractions;
using InvoiceService.Application.Invoices;
using InvoiceService.Domain.Invoices;
using InvoiceService.Domain.Outbox;
using Microsoft.EntityFrameworkCore;

namespace InvoiceService.Infrastructure.Persistence;

public sealed class InvoiceStore(InvoiceDbContext db) : IInvoiceStore
{
    public async Task<string> NextInvoiceNumberAsync(CancellationToken ct)
    {
        var value = await db.Database
            .SqlQueryRaw<long>($"SELECT nextval('{InvoiceDbContext.InvoiceNumberSequence}') AS \"Value\"")
            .SingleAsync(ct);
        return InvoiceNumber.Format(value);
    }

    public async Task QueueAsync(Invoice invoice, ErpOutboxEntry entry, CancellationToken ct)
    {
        db.Invoices.Add(invoice);
        db.ErpOutbox.Add(entry);
        await db.SaveChangesAsync(ct);
    }

    public Task<Invoice?> FindAsync(string invoiceNumber, CancellationToken ct) =>
        db.Invoices.AsNoTracking().SingleOrDefaultAsync(i => i.InvoiceNumber == invoiceNumber, ct);

    public Task<Invoice> GetAsync(string invoiceNumber, CancellationToken ct) =>
        db.Invoices.AsNoTracking().SingleAsync(i => i.InvoiceNumber == invoiceNumber, ct);

    public async Task<InvoicePage> ListPageAsync(string? status, string? search, int skip, int take, CancellationToken ct)
    {
        var query = db.Invoices.AsNoTracking();
        if (status is not null)
            query = query.Where(i => i.Status == status);
        if (search is not null)
            query = query.Where(i => EF.Functions.ILike(i.InvoiceNumber, "%" + EscapeLike(search) + "%", "\\"));

        var total = await query.CountAsync(ct);
        var items = await query
            .OrderByDescending(i => i.CreatedAt).ThenByDescending(i => i.InvoiceNumber)
            .Skip(skip).Take(take)
            .ToListAsync(ct);
        return new InvoicePage(items, total);
    }

    public async Task<IReadOnlyDictionary<string, int>> CountByStatusAsync(CancellationToken ct) =>
        await db.Invoices.AsNoTracking()
            .GroupBy(i => i.Status)
            .Select(g => new { Status = g.Key, Count = g.Count() })
            .ToDictionaryAsync(g => g.Status, g => g.Count, ct);

    public Task<int> CountStuckAsync(DateTimeOffset olderThan, CancellationToken ct) =>
        db.Invoices.AsNoTracking().CountAsync(
            i => (i.Status == InvoiceStatus.Sent || i.Status == InvoiceStatus.Processing) && i.UpdatedAt < olderThan, ct);

    /// <summary>The characters that mean something in a LIKE pattern are searched for as themselves.</summary>
    private static string EscapeLike(string text) =>
        text.Replace("\\", "\\\\").Replace("%", "\\%").Replace("_", "\\_");

    public Task<int> MarkPendingIfFailedAsync(string invoiceNumber, DateTimeOffset now, CancellationToken ct) =>
        db.Invoices
            .Where(i => i.InvoiceNumber == invoiceNumber && i.Status == InvoiceStatus.Failed)
            .ExecuteUpdateAsync(s => s
                .SetProperty(i => i.Status, InvoiceStatus.Pending)
                .SetProperty(i => i.LastError, (string?)null)
                .SetProperty(i => i.UpdatedAt, now), ct);

    public Task WriteSendOutcomeAsync(
        string invoiceNumber, string status, string? erpReference, string? lastError, DateTimeOffset now, CancellationToken ct) =>
        db.Invoices
            .Where(i => i.InvoiceNumber == invoiceNumber)
            .ExecuteUpdateAsync(s => s
                .SetProperty(i => i.Status, status)
                .SetProperty(i => i.ErpReference, erpReference)
                .SetProperty(i => i.LastError, lastError)
                .SetProperty(i => i.UpdatedAt, now), ct);

    public async Task<Invoice?> LockAsync(string invoiceNumber, CancellationToken ct) =>
        (await db.Invoices
            .FromSql($"SELECT * FROM invoices WHERE invoice_number = {invoiceNumber} FOR UPDATE")
            .ToListAsync(ct))
        .SingleOrDefault();
}
