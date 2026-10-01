using InvoiceService.Data;
using Microsoft.EntityFrameworkCore;

namespace InvoiceService.Invoices;

public static class InvoiceEndpoints
{
    public static IEndpointRouteBuilder MapInvoiceEndpoints(this IEndpointRouteBuilder app)
    {
        var group = app.MapGroup("/api/v1/invoices").WithTags("Invoices");

        group.MapPost("/", CreateInvoice)
            .WithName("CreateInvoice")
            .WithSummary("Create an invoice and queue it for the ERP")
            .WithDescription(
                "Saves the invoice with a generated number (FTR-000001) and status Bekliyor, together with its " +
                "erp_outbox entry in the same transaction, and returns 202. The ERP is not called in this request; " +
                "the send happens in the background.")
            .Produces<InvoiceResponse>(StatusCodes.Status202Accepted)
            .ProducesValidationProblem();

        group.MapPost("/{invoiceNumber}/resend", ResendInvoice)
            .WithName("ResendInvoice")
            .WithSummary("Send a failed invoice to the ERP once more")
            .WithDescription(
                "Only for invoices with status Başarısız. Sends once and writes the outcome the same way as create. " +
                "No duplicate protection: if the ERP had already saved the invoice, it gets a second record there.")
            .Produces<InvoiceResponse>()
            .ProducesProblem(StatusCodes.Status404NotFound)
            .ProducesProblem(StatusCodes.Status409Conflict);

        group.MapGet("/{invoiceNumber}", GetInvoice)
            .WithName("GetInvoice")
            .WithSummary("The invoice as stored by the service")
            .Produces<InvoiceResponse>()
            .ProducesProblem(StatusCodes.Status404NotFound);

        return app;
    }

    private static async Task<IResult> CreateInvoice(
        CreateInvoiceRequest request,
        InvoiceDbContext db,
        TimeProvider time,
        ILoggerFactory loggerFactory)
    {
        var logger = loggerFactory.CreateLogger("InvoiceService.Invoices");
        var errors = request.Validate();
        if (errors.Count > 0)
        {
            logger.LogWarning("Rejected invalid invoice request");
            return Results.ValidationProblem(errors);
        }

        var now = time.GetUtcNow();
        var invoice = new Invoice
        {
            InvoiceNumber = await db.NextInvoiceNumberAsync(CancellationToken.None),
            CustomerCode = request.CustomerCode!,
            Amount = request.Amount!.Value,
            Currency = request.Currency!,
            InvoiceDate = request.InvoiceDate!.Value,
            Status = InvoiceStatus.Pending,
            CreatedAt = now,
            UpdatedAt = now
        };
        db.Invoices.Add(invoice);
        db.ErpOutbox.Add(new ErpOutboxEntry
        {
            InvoiceNumber = invoice.InvoiceNumber,
            Status = OutboxStatus.Pending,
            AttemptCount = 0,
            NextAttemptAt = now,
            CreatedAt = now
        });

        // One SaveChanges = one transaction: both rows are written or neither is. There is never an invoice that
        // nobody will send, nor a send queued for an invoice that does not exist.
        await db.SaveChangesAsync(CancellationToken.None);
        logger.LogInformation("Invoice queued invoice={InvoiceNumber}", invoice.InvoiceNumber);

        return Results.Accepted($"/api/v1/invoices/{Uri.EscapeDataString(invoice.InvoiceNumber)}", InvoiceResponse.From(invoice));
    }

    private static async Task<IResult> ResendInvoice(string invoiceNumber, InvoiceDbContext db, InvoiceSender sender)
    {
        var invoice = await db.Invoices.SingleOrDefaultAsync(i => i.InvoiceNumber == invoiceNumber);
        if (invoice is null)
            return NotFound(invoiceNumber);

        if (invoice.Status != InvoiceStatus.Failed)
        {
            return Results.Problem(
                statusCode: StatusCodes.Status409Conflict,
                title: "Invoice is not failed",
                detail: $"Invoice '{invoiceNumber}' has status {invoice.Status}; only {InvoiceStatus.Failed} invoices can be resent.");
        }

        return Results.Ok(InvoiceResponse.From(await sender.SendAsync(invoice)));
    }

    private static async Task<IResult> GetInvoice(string invoiceNumber, InvoiceDbContext db, CancellationToken ct)
    {
        var invoice = await db.Invoices.AsNoTracking().SingleOrDefaultAsync(i => i.InvoiceNumber == invoiceNumber, ct);
        return invoice is null ? NotFound(invoiceNumber) : Results.Ok(InvoiceResponse.From(invoice));
    }

    private static IResult NotFound(string invoiceNumber) =>
        Results.Problem(
            statusCode: StatusCodes.Status404NotFound,
            title: "Invoice not found",
            detail: $"No invoice '{invoiceNumber}' in the invoice service.");
}
