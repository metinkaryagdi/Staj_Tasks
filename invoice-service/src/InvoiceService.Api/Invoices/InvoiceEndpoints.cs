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

        group.MapPost("/resend", ResendInvoices)
            .WithName("ResendInvoices")
            .WithSummary("Queue several failed invoices again")
            .WithDescription(
                "Body: { \"invoiceNumbers\": [...] }, 1 to 100 numbers (400 otherwise); a number sent twice is resent once. " +
                "Every invoice follows the single resend's rules (only Başarısız, nothing is sent to the ERP in this request) " +
                "and gets its own result: queued, not_found, not_failed (with its current status) or error. The request is " +
                "200 whatever the results are; one invoice that is refused does not stop the others.")
            .Produces<BulkResendResponse>()
            .ProducesValidationProblem();

        group.MapGet("/", ListInvoices)
            .WithName("ListInvoices")
            .WithSummary("One page of invoices, newest first")
            .WithDescription(
                "status=Bekliyor, Gönderildi, İşleme Alındı, Onaylandı, Reddedildi or Başarısız narrows the list; search is part " +
                "of the invoice number (any case); stuck=true keeps only the invoices the summary counts as stuck (the same rule). " +
                "page starts at 1 (default 1), pageSize is 1 to 100 (default 20). The response " +
                "carries the page and the total number of invoices the filters match.")
            .Produces<InvoiceListResponse>()
            .ProducesValidationProblem();

        group.MapGet("/summary", Summary)
            .WithName("InvoiceSummary")
            .WithSummary("How many invoices are in each status, and how many are stuck")
            .WithDescription(
                "Every status is listed, with 0 when no invoice is in it. Stuck: Gönderildi or İşleme Alındı for longer than " +
                "Reconciliation:StuckAfterMinutes, the same rule the reconciliation uses to ask the ERP for the decision.")
            .Produces<InvoiceSummaryResponse>();

        group.MapGet("/{invoiceNumber}/details", GetDetails)
            .WithName("GetInvoiceDetails")
            .WithSummary("The invoice with its erp_outbox entry, its events and its reconciliation findings")
            .WithDescription(
                "Four reads, not one snapshot: a change made while the response is built can show in one part and not in another. " +
                "outbox is null for an invoice without an entry. 404 if the invoice does not exist.")
            .Produces<InvoiceDetailsResponse>()
            .ProducesProblem(StatusCodes.Status404NotFound);

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
                detail: $"Invoice '{invoiceNumber}' has status {result.CurrentStatus}; only {InvoiceStatus.Failed} invoices can be resent.",
                extensions: new Dictionary<string, object?>
                {
                    ["code"] = ProblemCodes.InvoiceNotFailed,
                    ["currentStatus"] = result.CurrentStatus
                }),
            _ => Results.Accepted(
                $"/api/v1/invoices/{Uri.EscapeDataString(invoiceNumber)}", InvoiceResponse.From(result.Invoice!))
        };
    }

    private static async Task<IResult> ResendInvoices(ResendInvoicesRequest request, ResendInvoicesHandler handler)
    {
        var result = await handler.HandleAsync(request);
        return result.Errors is not null
            ? Results.ValidationProblem(result.Errors)
            : Results.Ok(new BulkResendResponse(result.Items.Select(BulkResendItemResponse.From).ToList()));
    }

    private static async Task<IResult> ListInvoices(
        string? status, string? search, bool? stuck, int? page, int? pageSize, InvoiceQueries queries, CancellationToken ct)
    {
        var errors = new Dictionary<string, string[]>();
        if (status is not null && !InvoiceStatus.All.Contains(status))
            errors["status"] = [$"Must be one of: {string.Join(", ", InvoiceStatus.All)}."];
        if (page is < 1)
            errors["page"] = ["Must be 1 or greater."];
        if (pageSize is < 1 or > InvoiceQueries.MaxPageSize)
            errors["pageSize"] = [$"Must be between 1 and {InvoiceQueries.MaxPageSize}."];

        var currentPage = page ?? 1;
        var size = pageSize ?? InvoiceQueries.DefaultPageSize;
        // The rows to skip must fit an int; a page that far is empty anyway.
        if (currentPage > 1 && (long)(currentPage - 1) * size > int.MaxValue)
            errors["page"] = ["Too large for this page size."];
        if (errors.Count > 0)
            return Results.ValidationProblem(errors);

        var result = await queries.ListAsync(status, search, stuck ?? false, currentPage, size, ct);
        return Results.Ok(new InvoiceListResponse(
            result.Items.Select(InvoiceResponse.From).ToList(), currentPage, size, result.TotalCount,
            (result.TotalCount + size - 1) / size));
    }

    private static async Task<IResult> Summary(InvoiceQueries queries, CancellationToken ct)
    {
        var summary = await queries.SummaryAsync(ct);
        return Results.Ok(new InvoiceSummaryResponse(
            summary.Counts.Select(c => new StatusCountResponse(c.Status, c.Count)).ToList(),
            summary.Total, summary.StuckCount, summary.StuckAfterMinutes));
    }

    private static async Task<IResult> GetDetails(string invoiceNumber, InvoiceQueries queries, CancellationToken ct)
    {
        var details = await queries.DetailsAsync(invoiceNumber, ct);
        return details is null ? NotFound(invoiceNumber) : Results.Ok(InvoiceDetailsResponse.From(details));
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
            detail: $"No invoice '{invoiceNumber}' in the invoice service.",
            extensions: new Dictionary<string, object?> { ["code"] = ProblemCodes.InvoiceNotFound });
}
