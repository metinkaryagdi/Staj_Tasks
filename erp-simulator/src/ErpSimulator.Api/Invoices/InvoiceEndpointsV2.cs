using Microsoft.AspNetCore.Mvc;
using ErpSimulator.Application.Invoices;
using ErpSimulator.Application.Simulation;
using ErpSimulator.Domain.Invoices;

namespace ErpSimulator.Api.Invoices;

/// <summary>
/// API v2 on the same records as v1, whichever version received them: amounts are whole kuruş and an invoice number sent
/// again gets its existing record. The faults, the rate limit and the cancellation are v1's.
/// </summary>
public static class InvoiceEndpointsV2
{
    public static IEndpointRouteBuilder MapInvoiceEndpointsV2(this IEndpointRouteBuilder app)
    {
        var group = app.MapGroup("/api/v2/invoices").WithTags("Invoices v2");

        group.MapPost("/", CreateInvoice)
            .AddEndpointFilter(InvoiceEndpoints.LimitRate)
            .WithName("CreateInvoiceV2")
            .WithSummary("Submit an invoice, the amount in kuruş")
            .WithDescription(
                "Same behaviors as v1. An invoice number that already has a record, from either version, creates no new record: " +
                "202 with the existing record, even if the content differs (no behavior is drawn). Its events use the v2 format.")
            .Produces<InvoiceAcceptedResponseV2>(StatusCodes.Status202Accepted)
            .ProducesValidationProblem()
            .ProducesProblem(StatusCodes.Status429TooManyRequests)
            .ProducesProblem(StatusCodes.Status500InternalServerError);

        group.MapGet("/", ListInvoices)
            .WithName("ListInvoicesV2")
            .WithSummary("List the invoices recorded in a time range, the amounts in kuruş")
            .Produces<InvoiceListResponseV2>()
            .ProducesValidationProblem();

        group.MapGet("/{invoiceNumber}", GetInvoice)
            .WithName("GetInvoiceV2")
            .WithSummary("Look up an invoice by invoice number, the amounts in kuruş")
            .Produces<InvoiceLookupResponseV2>()
            .ProducesProblem(StatusCodes.Status404NotFound);

        group.MapPost("/{invoiceNumber}/cancel", InvoiceEndpoints.CancelInvoice)
            .AddEndpointFilter(InvoiceEndpoints.LimitRate)
            .WithName("CancelInvoiceV2")
            .WithSummary("Cancel an invoice, whichever version received it")
            .WithDescription("Same as v1. The events keep the format of the version that received the invoice.")
            .Produces<CancellationAcceptedResponse>(StatusCodes.Status202Accepted)
            .ProducesProblem(StatusCodes.Status404NotFound)
            .ProducesProblem(StatusCodes.Status409Conflict)
            .ProducesProblem(StatusCodes.Status429TooManyRequests)
            .ProducesProblem(StatusCodes.Status500InternalServerError);

        return app;
    }

    private static long ToKurus(decimal amount) => (long)(amount * 100m);

    private static Task<IResult> CreateInvoice(
        CreateInvoiceRequestV2 request, HttpContext http, SubmitInvoiceHandler handler, IOptions<SimulatorOptions> options) =>
        InvoiceEndpoints.SubmitAsync(request.ToRequest(), ErpApiVersion.V2, Accepted, http, handler, options);

    private static IResult Accepted(ErpInvoice invoice) =>
        Results.Accepted(
            $"/api/v2/invoices/{Uri.EscapeDataString(invoice.InvoiceNumber)}",
            new InvoiceAcceptedResponseV2(invoice.ErpReference, invoice.InvoiceNumber, invoice.CustomerCode, ToKurus(invoice.Amount),
                invoice.Currency, invoice.InvoiceDate, invoice.ReceivedAt));

    private static async Task<IResult> ListInvoices(
        [FromQuery(Name = "from")] DateTimeOffset? rangeStart,
        [FromQuery(Name = "to")] DateTimeOffset? rangeEnd,
        InvoiceListing listing,
        CancellationToken ct,
        int page = 1,
        int pageSize = 100)
    {
        var result = await listing.ListAsync(new InvoiceListRequest(rangeStart, rangeEnd, page, pageSize), ct);
        if (result.Errors is not null)
            return Results.ValidationProblem(result.Errors);

        var items = result.Page!.Items
            .Select(i => new InvoiceListItemResponseV2(
                i.InvoiceNumber, i.ErpReference, i.CustomerCode, ToKurus(i.Amount), i.Currency, i.InvoiceDate, i.ReceivedAt,
                result.Page.Cancellations.GetValueOrDefault(i.InvoiceNumber)?.CancelReference))
            .ToList();
        return Results.Ok(new InvoiceListResponseV2(page, pageSize, result.Page.TotalCount, items));
    }

    private static async Task<IResult> GetInvoice(string invoiceNumber, InvoiceLookup lookup, CancellationToken ct)
    {
        var found = await lookup.FindAsync(invoiceNumber, ct);
        var records = found.Records
            .Select(i => new InvoiceRecordResponseV2(
                i.ErpReference, i.CustomerCode, ToKurus(i.Amount), i.Currency, i.InvoiceDate, i.ReceivedAt))
            .ToList();

        if (records.Count == 0)
        {
            return Results.Problem(
                statusCode: StatusCodes.Status404NotFound,
                title: "Invoice not found",
                detail: $"No ERP record for invoice '{invoiceNumber}'.");
        }

        var decision = found.Decision;
        return Results.Ok(new InvoiceLookupResponseV2(
            invoiceNumber, true, records[0].ErpReference, records.Count, records,
            decision.Kind, decision.Reason, decision.DecidedAt,
            found.Cancellation?.CancelReference, found.Cancellation?.CancelledAt));
    }
}
