using InvoiceService.Application.Abstractions;
using InvoiceService.Domain.Invoices;
using InvoiceService.Domain.Outbox;

namespace InvoiceService.Application.Invoices;

/// <summary>The invoice that was queued, or what is wrong with the request (400).</summary>
public sealed record CreateInvoiceResult(Invoice? Invoice, Dictionary<string, string[]>? Errors);

/// <summary>
/// Saves the invoice (Bekliyor) together with its erp_outbox entry in one save. The ERP is not called here; the
/// background worker sends it.
/// </summary>
public sealed class CreateInvoiceHandler(IInvoiceStore invoices, TimeProvider time, ILoggerFactory loggerFactory)
{
    private readonly ILogger _logger = loggerFactory.CreateLogger(InvoiceLog.Category);

    public async Task<CreateInvoiceResult> HandleAsync(CreateInvoiceRequest request)
    {
        var errors = request.Validate();
        if (errors.Count > 0)
        {
            _logger.LogWarning("Rejected invalid invoice request");
            return new CreateInvoiceResult(null, errors);
        }

        var now = time.GetUtcNow();
        var invoice = new Invoice
        {
            InvoiceNumber = await invoices.NextInvoiceNumberAsync(CancellationToken.None),
            CustomerCode = request.CustomerCode!,
            Amount = request.Amount!.Value,
            Currency = request.Currency!,
            InvoiceDate = request.InvoiceDate!.Value,
            Status = InvoiceStatus.Pending,
            CreatedAt = now,
            UpdatedAt = now
        };
        var entry = new ErpOutboxEntry
        {
            InvoiceNumber = invoice.InvoiceNumber,
            Status = OutboxStatus.Pending,
            AttemptCount = 0,
            NextAttemptAt = now,
            CreatedAt = now
        };

        // One save = one transaction: both rows are written or neither is. There is never an invoice that
        // nobody will send, nor a send queued for an invoice that does not exist.
        await invoices.QueueAsync(invoice, entry, CancellationToken.None);
        _logger.LogInformation("Invoice queued invoice={InvoiceNumber}", invoice.InvoiceNumber);

        return new CreateInvoiceResult(invoice, null);
    }
}
