using ErpSimulator.Application.Abstractions;
using ErpSimulator.Domain.Invoices;
using ErpSimulator.Domain.Webhooks;
using Microsoft.EntityFrameworkCore;

namespace ErpSimulator.Infrastructure.Persistence;

public sealed class ErpInvoiceStore(ErpDbContext db) : IErpInvoiceStore
{
    public async Task<IUnitOfWorkTransaction> LockInvoiceNumberAsync(string invoiceNumber)
    {
        var transaction = await db.Database.BeginTransactionAsync(CancellationToken.None);
        await db.Database.ExecuteSqlInterpolatedAsync(
            $"SELECT pg_advisory_xact_lock(hashtextextended({invoiceNumber}, 0))", CancellationToken.None);
        return new UnitOfWork.Transaction(transaction);
    }

    public Task<ErpInvoice?> FindFirstAsync(string invoiceNumber) =>
        db.Invoices
            .AsNoTracking()
            .Where(i => i.InvoiceNumber == invoiceNumber)
            .OrderBy(i => i.Id)
            .FirstOrDefaultAsync(CancellationToken.None);

    public async Task<IReadOnlyList<ErpInvoice>> ListAsync(string invoiceNumber, CancellationToken ct) =>
        await db.Invoices
            .AsNoTracking()
            .Where(i => i.InvoiceNumber == invoiceNumber)
            .OrderBy(i => i.Id)
            .ToListAsync(ct);

    public async Task SaveAsync(ErpInvoice invoice, Func<ErpInvoice, IEnumerable<WebhookDelivery>> planEvents)
    {
        // With IdempotentInvoices on, the invoice number lock's transaction is already open; it is committed here too.
        var transaction = db.Database.CurrentTransaction ?? await db.Database.BeginTransactionAsync(CancellationToken.None);

        db.Invoices.Add(invoice);
        // CancellationToken.None: once the ERP decides to save, a client disconnect must not undo it.
        await db.SaveChangesAsync(CancellationToken.None);
        db.WebhookDeliveries.AddRange(planEvents(invoice));
        await db.SaveChangesAsync(CancellationToken.None);

        await transaction.CommitAsync(CancellationToken.None);
        await transaction.DisposeAsync();
    }
}
