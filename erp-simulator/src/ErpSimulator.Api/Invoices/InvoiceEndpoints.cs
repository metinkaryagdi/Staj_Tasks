using System.Globalization;
using ErpSimulator.Application.Invoices;
using ErpSimulator.Application.Simulation;
using ErpSimulator.Domain.Invoices;

namespace ErpSimulator.Api.Invoices;

public static class InvoiceEndpoints
{
    public static IEndpointRouteBuilder MapInvoiceEndpoints(this IEndpointRouteBuilder app)
    {
        var group = app.MapGroup("/api/v1/invoices").WithTags("Invoices");

        group.MapPost("/", CreateInvoice)
            .WithName("CreateInvoice")
            .WithSummary("Submit an invoice to the ERP")
            .WithDescription(
                "The simulator picks one behavior per request from the configured rates: " +
                "Success (202, saved), Busy (429 + Retry-After, not saved), ServerError (500, not saved), " +
                "SaveThenError (500, but saved), LateResponse (saved, 202 after the configured delay, default 30s). " +
                "By default duplicates are NOT prevented: the same invoice number creates a new record with a new ERP reference. " +
                "With Simulator:IdempotentInvoices on, an invoice number that already has a record is not saved again: " +
                "the same content returns 202 with the existing reference (no behavior is drawn), different content returns 409.")
            .Produces<InvoiceAcceptedResponse>(StatusCodes.Status202Accepted)
            .ProducesValidationProblem()
            .ProducesProblem(StatusCodes.Status409Conflict)
            .ProducesProblem(StatusCodes.Status429TooManyRequests)
            .ProducesProblem(StatusCodes.Status500InternalServerError);

        group.MapGet("/{invoiceNumber}", GetInvoice)
            .WithName("GetInvoice")
            .WithSummary("Look up an invoice by invoice number")
            .WithDescription(
                "Returns the ERP reference(s) recorded for the invoice number. No faults are injected here. " +
                "erpReference is the first record; records lists all of them when duplicates exist.")
            .Produces<InvoiceLookupResponse>()
            .ProducesProblem(StatusCodes.Status404NotFound);

        return app;
    }

    private static async Task<IResult> CreateInvoice(
        CreateInvoiceRequest request,
        HttpContext http,
        SubmitInvoiceHandler handler,
        IOptions<SimulatorOptions> options)
    {
        var result = await handler.HandleAsync(request, http.RequestAborted);
        switch (result.Outcome)
        {
            case SubmitOutcome.Invalid:
                return Results.ValidationProblem(result.Errors!);

            case SubmitOutcome.Duplicate:
                return Accepted(result.Invoice!);

            case SubmitOutcome.Conflict:
                return Results.Problem(
                    statusCode: StatusCodes.Status409Conflict,
                    title: "Invoice number already used",
                    detail: $"Invoice '{request.InvoiceNumber}' is already recorded as {result.Invoice!.ErpReference} with different content.");
        }

        var decision = result.Decision!;
        switch (decision.Behavior)
        {
            case Behavior.Success:
                return Accepted(result.Invoice!);

            case Behavior.Busy:
                http.Response.Headers.RetryAfter = FormatRetryAfter(decision.RetryAfterSeconds, options.Value.RetryAfterFormat);
                return Results.Problem(
                    statusCode: StatusCodes.Status429TooManyRequests,
                    title: "ERP is busy",
                    detail: $"Try again in {decision.RetryAfterSeconds} seconds.");

            case Behavior.ServerError:
            case Behavior.SaveThenError:
                return Results.Problem(
                    statusCode: StatusCodes.Status500InternalServerError,
                    title: "ERP internal error");

            case Behavior.LateResponse:
                return result.ClientGone ? Results.Empty : Accepted(result.Invoice!);

            default:
                throw new InvalidOperationException($"Unknown behavior {decision.Behavior}");
        }
    }

    private static async Task<IResult> GetInvoice(string invoiceNumber, InvoiceLookup lookup, CancellationToken ct)
    {
        var records = (await lookup.RecordsAsync(invoiceNumber, ct))
            .Select(i => new InvoiceRecordResponse(
                i.ErpReference, i.CustomerCode, i.Amount, i.Currency, i.InvoiceDate, i.ReceivedAt))
            .ToList();

        if (records.Count == 0)
        {
            return Results.Problem(
                statusCode: StatusCodes.Status404NotFound,
                title: "Invoice not found",
                detail: $"No ERP record for invoice '{invoiceNumber}'.");
        }

        return Results.Ok(new InvoiceLookupResponse(
            invoiceNumber, true, records[0].ErpReference, records.Count, records));
    }

    private static IResult Accepted(ErpInvoice invoice) =>
        Results.Accepted(
            $"/api/v1/invoices/{Uri.EscapeDataString(invoice.InvoiceNumber)}",
            new InvoiceAcceptedResponse(invoice.ErpReference, invoice.InvoiceNumber, invoice.ReceivedAt));

    internal static string FormatRetryAfter(int seconds, RetryAfterFormat format) => format switch
    {
        RetryAfterFormat.HttpDate => DateTimeOffset.UtcNow.AddSeconds(seconds).ToString("R", CultureInfo.InvariantCulture),
        _ => seconds.ToString(CultureInfo.InvariantCulture)
    };
}
