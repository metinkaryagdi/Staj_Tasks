using System.Globalization;
using Microsoft.AspNetCore.Mvc;
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
            .AddEndpointFilter(LimitRate)
            .WithName("CreateInvoice")
            .WithSummary("Submit an invoice to the ERP")
            .WithDescription(
                "At most RateLimit:PermitsPerSecond requests per clock second are accepted, shared by every client; the rest get " +
                "429 with Retry-After: 1 (title 'Rate limit exceeded'), before any behavior is drawn. " +
                "The simulator picks one behavior per accepted request from the configured rates: " +
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

        group.MapGet("/", ListInvoices)
            .WithName("ListInvoices")
            .WithSummary("List the invoices recorded in a time range")
            .WithDescription(
                "Every record whose receivedAt is in [from, to), ordered by receivedAt then id, one page at a time " +
                "(page starts at 1; pageSize defaults to 100, at most 500, above that is a 400). A duplicated invoice number " +
                "is listed once per record. No faults are injected here. Write a '+' in a time offset as %2B.")
            .Produces<InvoiceListResponse>()
            .ProducesValidationProblem();

        group.MapGet("/{invoiceNumber}", GetInvoice)
            .WithName("GetInvoice")
            .WithSummary("Look up an invoice by invoice number")
            .WithDescription(
                "Returns the ERP reference(s) recorded for the invoice number. No faults are injected here. " +
                "erpReference is the first record; records lists all of them when duplicates exist. " +
                "decision (none, received, approved, rejected) is the first record's, with reason (rejected only) and decided_at; " +
                "it shows once its time has come, even if the event was never sent.")
            .Produces<InvoiceLookupResponse>()
            .ProducesProblem(StatusCodes.Status404NotFound);

        return app;
    }

    /// <summary>A rejected client may try again after this long: the bucket is refilled at every clock second.</summary>
    private const int RateLimitRetryAfterSeconds = 1;

    /// <summary>
    /// Runs before the handler: a request over the rate limit draws no behavior and saves nothing. Logged as
    /// reason=rateLimited, apart from the Busy behavior's 429.
    /// </summary>
    private static async ValueTask<object?> LimitRate(EndpointFilterInvocationContext context, EndpointFilterDelegate next)
    {
        var http = context.HttpContext;
        var limiter = http.RequestServices.GetRequiredService<InvoiceRateLimiter>();
        if (limiter.TryAcquire())
            return await next(context);

        http.RequestServices.GetRequiredService<ILoggerFactory>().CreateLogger("ErpSimulator.Invoices")
            .LogInformation("Invoice request rejected status=429 reason=rateLimited limit={Limit}/s retryAfter={RetryAfter}s",
                limiter.PermitsPerSecond, RateLimitRetryAfterSeconds);
        http.Response.Headers.RetryAfter = RateLimitRetryAfterSeconds.ToString(CultureInfo.InvariantCulture);
        return Results.Problem(
            statusCode: StatusCodes.Status429TooManyRequests,
            title: "Rate limit exceeded",
            detail: $"At most {limiter.PermitsPerSecond} invoice requests per second are accepted. Try again in {RateLimitRetryAfterSeconds} second.");
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
            .Select(i => new InvoiceListItemResponse(
                i.InvoiceNumber, i.ErpReference, i.CustomerCode, i.Amount, i.Currency, i.InvoiceDate, i.ReceivedAt))
            .ToList();
        return Results.Ok(new InvoiceListResponse(page, pageSize, result.Page.TotalCount, items));
    }

    private static async Task<IResult> GetInvoice(string invoiceNumber, InvoiceLookup lookup, CancellationToken ct)
    {
        var found = await lookup.FindAsync(invoiceNumber, ct);
        var records = found.Records
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

        var decision = found.Decision;
        return Results.Ok(new InvoiceLookupResponse(
            invoiceNumber, true, records[0].ErpReference, records.Count, records,
            decision.Kind, decision.Reason, decision.DecidedAt));
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
