using InvoiceService.Application.Abstractions;
using InvoiceService.Domain.Operators;
using Microsoft.EntityFrameworkCore;

namespace InvoiceService.Infrastructure.Persistence;

public sealed class OperatorActionStore(InvoiceDbContext db) : IOperatorActionStore
{
    // A plain INSERT rather than Add + SaveChanges: nothing stays tracked if it fails, so a later save in the same scope
    // (the next invoice of a bulk resend) cannot write it by accident.
    public async Task RecordAsync(OperatorAction action, CancellationToken ct) =>
        await db.Database.ExecuteSqlAsync($"""
            INSERT INTO operator_actions (operator_name, action, invoice_number, result, created_at)
            VALUES ({action.OperatorName}, {action.Action}, {action.InvoiceNumber}, {action.Result}, {action.CreatedAt})
            """, ct);

    public async Task<IReadOnlyList<OperatorAction>> ListOfInvoiceAsync(string invoiceNumber, CancellationToken ct) =>
        await db.OperatorActions.AsNoTracking()
            .Where(a => a.InvoiceNumber == invoiceNumber)
            .OrderByDescending(a => a.Id)
            .ToListAsync(ct);
}
