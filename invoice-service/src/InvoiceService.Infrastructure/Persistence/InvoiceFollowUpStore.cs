using InvoiceService.Application.Abstractions;
using InvoiceService.Domain.Invoices;
using Microsoft.EntityFrameworkCore;

namespace InvoiceService.Infrastructure.Persistence;

public sealed class InvoiceFollowUpStore(InvoiceDbContext db) : IInvoiceFollowUpStore
{
    public Task<InvoiceFollowUp?> FindOpenAsync(string invoiceNumber, CancellationToken ct) =>
        db.InvoiceFollowUps.AsNoTracking().SingleOrDefaultAsync(f => f.InvoiceNumber == invoiceNumber && f.ClosedAt == null, ct);

    public async Task<IReadOnlyList<InvoiceFollowUp>> ListAsync(string invoiceNumber, CancellationToken ct) =>
        await db.InvoiceFollowUps.AsNoTracking().Where(f => f.InvoiceNumber == invoiceNumber)
            .OrderByDescending(f => f.OpenedAt).ThenByDescending(f => f.Id).ToListAsync(ct);

    public async Task AddAsync(InvoiceFollowUp followUp, CancellationToken ct)
    {
        db.InvoiceFollowUps.Add(followUp);
        await db.SaveChangesAsync(ct);
    }

    public Task CloseAsync(long id, string closedBy, DateTimeOffset closedAt, CancellationToken ct) =>
        db.InvoiceFollowUps.Where(f => f.Id == id && f.ClosedAt == null)
            .ExecuteUpdateAsync(s => s.SetProperty(f => f.ClosedAt, closedAt).SetProperty(f => f.ClosedBy, closedBy), ct);

    public async Task<IReadOnlyDictionary<string, string>> OpenNamesAsync(
        IReadOnlyCollection<string> invoiceNumbers, CancellationToken ct) =>
        await db.InvoiceFollowUps.AsNoTracking()
            .Where(f => invoiceNumbers.Contains(f.InvoiceNumber) && f.ClosedAt == null)
            .ToDictionaryAsync(f => f.InvoiceNumber, f => f.OperatorName, ct);
}
