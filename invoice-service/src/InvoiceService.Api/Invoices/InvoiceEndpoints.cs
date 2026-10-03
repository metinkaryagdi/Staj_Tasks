using InvoiceService.Application.Invoices;
using InvoiceService.Domain.Invoices;

namespace InvoiceService.Api.Invoices;

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
                "status=Bekliyor, Gönderildi, İşleme Alındı, Onaylandı, Reddedildi or Başarısız; without it every invoice is listed. Ordered by invoice number. " +
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

    private static async Task<IResult> CreateInvoice(CreateInvoiceRequest request, CreateInvoiceHandler handler)
    {
        var result = await handler.HandleAsync(request);
        if (result.Errors is not null)
            return Results.ValidationProblem(result.Errors);

        var invoice = result.Invoice!;
        return Results.Accepted($"/api/v1/invoices/{Uri.EscapeDataString(invoice.InvoiceNumber)}", InvoiceResponse.From(invoice));
    }

    private static async Task<IResult> ResendInvoice(string invoiceNumber, ResendInvoiceHandler handler)
    {
        var result = await handler.HandleAsync(invoiceNumber);
        return result.Status switch
        {
            ResendStatus.NotFound => NotFound(invoiceNumber),
            ResendStatus.NotFailed => Results.Problem(
                statusCode: StatusCodes.Status409Conflict,
                title: "Invoice is not failed",
                detail: $"Invoice '{invoiceNumber}' has status {result.CurrentStatus}; only {InvoiceStatus.Failed} invoices can be resent."),
            _ => Results.Accepted(
                $"/api/v1/invoices/{Uri.EscapeDataString(invoiceNumber)}", InvoiceResponse.From(result.Invoice!))
        };
    }

    private static async Task<IResult> ListInvoices(string? status, InvoiceQueries queries, CancellationToken ct)
    {
        var statuses = InvoiceStatus.All;
        if (status is not null && !statuses.Contains(status))
        {
            return Results.ValidationProblem(new Dictionary<string, string[]>
            {
                ["status"] = [$"Must be one of: {string.Join(", ", statuses)}."]
            });
        }

        var invoices = await queries.ListAsync(status, ct);
        return Results.Ok(invoices.Select(InvoiceResponse.From));
    }

    private static async Task<IResult> GetInvoice(string invoiceNumber, InvoiceQueries queries, CancellationToken ct)
    {
        var invoice = await queries.FindAsync(invoiceNumber, ct);
        return invoice is null ? NotFound(invoiceNumber) : Results.Ok(InvoiceResponse.From(invoice));
    }

    private static IResult NotFound(string invoiceNumber) =>
        Results.Problem(
            statusCode: StatusCodes.Status404NotFound,
            title: "Invoice not found",
            detail: $"No invoice '{invoiceNumber}' in the invoice service.");
}
