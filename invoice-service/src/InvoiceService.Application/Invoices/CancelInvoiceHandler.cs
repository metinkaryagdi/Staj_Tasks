using InvoiceService.Application.Abstractions;
using InvoiceService.Domain.Invoices;
using InvoiceService.Domain.Operators;
using InvoiceService.Domain.Outbox;

namespace InvoiceService.Application.Invoices;

public enum CancelStatus
{
    /// <summary>The cancellation is queued in erp_outbox, new or a Başarısız one again (202).</summary>
    Queued,

    /// <summary>There is no such invoice (404).</summary>
    NotFound,

    /// <summary>The ERP rejected the invoice (409).</summary>
    Rejected,

    /// <summary>The invoice is İptal Edildi, or its cancellation is waiting or done (409).</summary>
    AlreadyRequested
}

/// <summary>
/// Queues an invoice's cancellation in erp_outbox. Does not call the ERP; the worker sends it once the invoice's own send
/// is done, so the ERP never sees the cancellation before the invoice. The same request queues a Başarısız cancellation
/// again, under the same rule. The invoice's row is locked first, so a resend of the same invoice waits for this and then
/// sees the cancellation. Who asked for it and how it ended is recorded in operator_actions, in the same transaction.
/// </summary>
public sealed class CancelInvoiceHandler(
    IUnitOfWork unitOfWork, IInvoiceStore invoices, IOutboxStore outbox, IOperatorActionStore actions, TimeProvider time,
    ILoggerFactory loggerFactory)
{
    private readonly ILogger _logger = loggerFactory.CreateLogger(InvoiceLog.Category);

    public async Task<CancelStatus> HandleAsync(string invoiceNumber, OperatorIdentity by)
    {
        var now = time.GetUtcNow();
        await using var transaction = await unitOfWork.BeginAsync(CancellationToken.None);

        var invoice = await invoices.LockAsync(invoiceNumber, CancellationToken.None);
        var status = invoice is null ? CancelStatus.NotFound
            : invoice.Status == InvoiceStatus.Rejected ? CancelStatus.Rejected
            : invoice.Status == InvoiceStatus.Cancelled ? CancelStatus.AlreadyRequested
            : await outbox.AddCancelAsync(invoiceNumber, now, CancellationToken.None) ? CancelStatus.Queued
            : CancelStatus.AlreadyRequested;

        var result = status switch
        {
            CancelStatus.Queued => OperatorActionResult.Queued,
            CancelStatus.NotFound => OperatorActionResult.NotFound,
            CancelStatus.Rejected => OperatorActionResult.NotFailed(InvoiceStatus.Rejected),
            _ => OperatorActionResult.CancelAlreadyRequested
        };
        await actions.RecordAsync(
            ResendInvoiceHandler.Record(by, OperatorActionType.Cancel, invoiceNumber, result, now), CancellationToken.None);
        await transaction.CommitAsync(CancellationToken.None);

        if (status == CancelStatus.Queued)
        {
            _logger.LogInformation("Invoice cancellation queued invoice={InvoiceNumber} operator={Operator} sub={OperatorSub}",
                invoiceNumber, by.Name, by.Sub);
        }

        return status;
    }
}
