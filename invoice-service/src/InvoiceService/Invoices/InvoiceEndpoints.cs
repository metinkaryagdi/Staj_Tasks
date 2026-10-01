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
            .WithSummary("Queue a failed invoice again")
            .WithDescription(
                "Only for invoices with status Başarısız. Does not call the ERP: resets the invoice's erp_outbox entry " +
                "(Bekliyor, 0 attempts, due now) and sets the invoice to Bekliyor, then returns 202. The worker sends it " +
                "again by the usual rules, asking the ERP first so an invoice the ERP already shows is not posted again. " +
                "409 if the invoice is not Başarısız, 404 if it does not exist.")
            .Produces<InvoiceResponse>(StatusCodes.Status202Accepted)
            .ProducesProblem(StatusCodes.Status404NotFound)
            .ProducesProblem(StatusCodes.Status409Conflict);

        group.MapGet("/", ListInvoices)
            .WithName("ListInvoices")
            .WithSummary("Invoices, optionally filtered by status")
            .WithDescription(
                "status=Bekliyor, Gönderildi or Başarısız; without it every invoice is listed. Ordered by invoice number. " +
                "Used by the tests to wait until the queue is empty (no Bekliyor left).")
            .Produces<InvoiceResponse[]>()
            .ProducesValidationProblem();

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

    private static async Task<IResult> ResendInvoice(
        string invoiceNumber, InvoiceDbContext db, TimeProvider time, ILoggerFactory loggerFactory)
    {
        var now = time.GetUtcNow();
        await using var transaction = await db.Database.BeginTransactionAsync();

        // Conditional: only a Başarısız invoice moves to Bekliyor. Two resends at the same time cannot both queue it;
        // the second finds it Bekliyor and gets 409.
        var queued = await db.Invoices
            .Where(i => i.InvoiceNumber == invoiceNumber && i.Status == InvoiceStatus.Failed)
            .ExecuteUpdateAsync(s => s
                .SetProperty(i => i.Status, InvoiceStatus.Pending)
                .SetProperty(i => i.LastError, (string?)null)
                .SetProperty(i => i.UpdatedAt, now));

        if (queued == 0)
        {
            var current = await db.Invoices.AsNoTracking().SingleOrDefaultAsync(i => i.InvoiceNumber == invoiceNumber);
            if (current is null)
                return NotFound(invoiceNumber);

            return Results.Problem(
                statusCode: StatusCodes.Status409Conflict,
                title: "Invoice is not failed",
                detail: $"Invoice '{invoiceNumber}' has status {current.Status}; only {InvoiceStatus.Failed} invoices can be resent.");
        }

        // Reset the entry so the worker treats it like a new one: all attempts (Outbox:MaxAttempts) again, due now. Insert if missing:
        // invoices that failed before the outbox existed (Gün 2) have no entry.
        await db.Database.ExecuteSqlAsync($"""
            INSERT INTO erp_outbox (invoice_number, status, attempt_count, next_attempt_at, created_at)
            VALUES ({invoiceNumber}, {OutboxStatus.Pending}, 0, {now}, {now})
            ON CONFLICT (invoice_number) DO UPDATE
            SET status = EXCLUDED.status,
                attempt_count = 0,
                next_attempt_at = EXCLUDED.next_attempt_at,
                last_error = NULL,
                processed_at = NULL,
                locked_until = NULL,
                locked_by = NULL,
                claim_token = NULL
            """);

        await transaction.CommitAsync();
        loggerFactory.CreateLogger("InvoiceService.Invoices").LogInformation("Invoice queued again invoice={InvoiceNumber}", invoiceNumber);

        var invoice = await db.Invoices.AsNoTracking().SingleAsync(i => i.InvoiceNumber == invoiceNumber);
        return Results.Accepted($"/api/v1/invoices/{Uri.EscapeDataString(invoiceNumber)}", InvoiceResponse.From(invoice));
    }

    private static async Task<IResult> ListInvoices(string? status, InvoiceDbContext db, CancellationToken ct)
    {
        string[] statuses = [InvoiceStatus.Pending, InvoiceStatus.Sent, InvoiceStatus.Failed];
        if (status is not null && !statuses.Contains(status))
        {
            return Results.ValidationProblem(new Dictionary<string, string[]>
            {
                ["status"] = [$"Must be one of: {string.Join(", ", statuses)}."]
            });
        }

        var query = db.Invoices.AsNoTracking();
        if (status is not null)
            query = query.Where(i => i.Status == status);

        var invoices = await query.OrderBy(i => i.InvoiceNumber).ToListAsync(ct);
        return Results.Ok(invoices.Select(InvoiceResponse.From));
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
