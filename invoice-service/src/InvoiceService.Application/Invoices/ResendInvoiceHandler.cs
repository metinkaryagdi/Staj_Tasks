using InvoiceService.Application.Abstractions;
using InvoiceService.Domain.Invoices;
using InvoiceService.Domain.Operators;

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
/// Who asked for it and how it ended is recorded in operator_actions, in the same transaction as the change.
/// </summary>
public sealed class ResendInvoiceHandler(
    IUnitOfWork unitOfWork, IInvoiceStore invoices, IOutboxStore outbox, IOperatorActionStore actions, TimeProvider time,
    ILoggerFactory loggerFactory)
{
    private readonly ILogger _logger = loggerFactory.CreateLogger(InvoiceLog.Category);

    /// <param name="action">How the operator asked for it: <see cref="OperatorActionType.Resend"/> or, one invoice of a
    /// bulk request, <see cref="OperatorActionType.BulkResend"/>.</param>
    public async Task<ResendInvoiceResult> HandleAsync(
        string invoiceNumber, string operatorName, string action = OperatorActionType.Resend)
    {
        var now = time.GetUtcNow();
        await using var transaction = await unitOfWork.BeginAsync(CancellationToken.None);

        // Conditional: only a Başarısız invoice moves to Bekliyor. Two resends at the same time cannot both queue it;
        // the second finds it Bekliyor and is refused.
        var queued = await invoices.MarkPendingIfFailedAsync(invoiceNumber, now, CancellationToken.None);

        if (queued == 0)
        {
            var current = await invoices.FindAsync(invoiceNumber, CancellationToken.None);
            var refused = current is null
                ? new ResendInvoiceResult(ResendStatus.NotFound)
                : new ResendInvoiceResult(ResendStatus.NotFailed, CurrentStatus: current.Status);
            await actions.RecordAsync(Record(operatorName, action, invoiceNumber, ResultText(refused), now), CancellationToken.None);
            await transaction.CommitAsync(CancellationToken.None);
            return refused;
        }

        // Reset the entry so the worker treats it like a new one; inserted if missing (invoices that failed before
        // the outbox existed).
        await outbox.ResetAsync(invoiceNumber, now, CancellationToken.None);
        await actions.RecordAsync(Record(operatorName, action, invoiceNumber, OperatorActionResult.Queued, now), CancellationToken.None);

        await transaction.CommitAsync(CancellationToken.None);
        _logger.LogInformation("Invoice queued again invoice={InvoiceNumber} operator={Operator}", invoiceNumber, operatorName);

        var invoice = await invoices.GetAsync(invoiceNumber, CancellationToken.None);
        return new ResendInvoiceResult(ResendStatus.Queued, invoice);
    }

    private static string ResultText(ResendInvoiceResult result) => result.Status == ResendStatus.NotFound
        ? OperatorActionResult.NotFound
        : OperatorActionResult.NotFailed(result.CurrentStatus!);

    /// <summary>A number too long to be an invoice is cut to fit the column; it was not found either way.</summary>
    public static OperatorAction Record(string operatorName, string action, string invoiceNumber, string result, DateTimeOffset now) =>
        new()
        {
            OperatorName = operatorName, Action = action,
            InvoiceNumber = invoiceNumber.Length <= OperatorAction.MaxInvoiceNumberLength
                ? invoiceNumber
                : invoiceNumber[..OperatorAction.MaxInvoiceNumberLength],
            Result = result, CreatedAt = now
        };
}
