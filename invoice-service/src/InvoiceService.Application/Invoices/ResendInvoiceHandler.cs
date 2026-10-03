using InvoiceService.Application.Abstractions;
using InvoiceService.Domain.Invoices;

namespace InvoiceService.Application.Invoices;

public enum ResendStatus
{
    /// <summary>The invoice was Başarısız and is Bekliyor again (202).</summary>
    Queued,

    /// <summary>There is no such invoice (404).</summary>
    NotFound,

    /// <summary>The invoice exists but is not Başarısız (409).</summary>
    NotFailed
}

/// <param name="Invoice">The invoice after it was queued again; set only for <see cref="ResendStatus.Queued"/>.</param>
/// <param name="CurrentStatus">The invoice's status; set only for <see cref="ResendStatus.NotFailed"/>.</param>
public sealed record ResendInvoiceResult(ResendStatus Status, Invoice? Invoice = null, string? CurrentStatus = null);

/// <summary>
/// Queues a Başarısız invoice again by resetting its outbox entry. Does not call the ERP; the worker sends it later.
/// </summary>
public sealed class ResendInvoiceHandler(
    IUnitOfWork unitOfWork, IInvoiceStore invoices, IOutboxStore outbox, TimeProvider time, ILoggerFactory loggerFactory)
{
    private readonly ILogger _logger = loggerFactory.CreateLogger(InvoiceLog.Category);

    public async Task<ResendInvoiceResult> HandleAsync(string invoiceNumber)
    {
        var now = time.GetUtcNow();
        await using var transaction = await unitOfWork.BeginAsync(CancellationToken.None);

        // Conditional: only a Başarısız invoice moves to Bekliyor. Two resends at the same time cannot both queue it;
        // the second finds it Bekliyor and is refused.
        var queued = await invoices.MarkPendingIfFailedAsync(invoiceNumber, now, CancellationToken.None);

        if (queued == 0)
        {
            var current = await invoices.FindAsync(invoiceNumber, CancellationToken.None);
            return current is null
                ? new ResendInvoiceResult(ResendStatus.NotFound)
                : new ResendInvoiceResult(ResendStatus.NotFailed, CurrentStatus: current.Status);
        }

        // Reset the entry so the worker treats it like a new one; inserted if missing (invoices that failed in Gün 2).
        await outbox.ResetAsync(invoiceNumber, now, CancellationToken.None);

        await transaction.CommitAsync(CancellationToken.None);
        _logger.LogInformation("Invoice queued again invoice={InvoiceNumber}", invoiceNumber);

        var invoice = await invoices.GetAsync(invoiceNumber, CancellationToken.None);
        return new ResendInvoiceResult(ResendStatus.Queued, invoice);
    }
}
