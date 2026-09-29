using System.Globalization;
using ErpSimulator.Data;
using ErpSimulator.Simulation;
using Microsoft.EntityFrameworkCore;
using Microsoft.Extensions.Options;

namespace ErpSimulator.Invoices;

public static class InvoiceEndpoints
{
    public static IEndpointRouteBuilder MapInvoiceEndpoints(this IEndpointRouteBuilder app)
    {
        var group = app.MapGroup("/api/v1/invoices");
        group.MapPost("/", CreateInvoice);
        group.MapGet("/{invoiceNumber}", GetInvoice);
        return app;
    }

    private static async Task<IResult> CreateInvoice(
        CreateInvoiceRequest request,
        HttpContext http,
        ErpDbContext db,
        BehaviorSelector selector,
        IOptions<SimulatorOptions> options,
        ILoggerFactory loggerFactory)
    {
        var logger = loggerFactory.CreateLogger("ErpSimulator.Invoices");

        // Invalid requests are rejected before a behavior is drawn so they don't shift the seeded sequence.
        var errors = request.Validate();
        if (errors.Count > 0)
        {
            logger.LogWarning("Rejected invalid invoice request invoice={InvoiceNumber}", request.InvoiceNumber);
            return Results.ValidationProblem(errors);
        }

        var decision = selector.Next();
        var settings = options.Value;

        if (decision.Behavior == Behavior.Busy)
        {
            logger.LogInformation(
                "ERP request #{Sequence} invoice={InvoiceNumber} behavior={Behavior} status=429 retryAfter={RetryAfter}s",
                decision.Sequence, request.InvoiceNumber, decision.Behavior, decision.RetryAfterSeconds);
        }
        else
        {
            logger.LogInformation(
                "ERP request #{Sequence} invoice={InvoiceNumber} behavior={Behavior} status={Status}",
                decision.Sequence, request.InvoiceNumber, decision.Behavior, StatusFor(decision.Behavior));
        }

        switch (decision.Behavior)
        {
            case Behavior.Success:
            {
                var invoice = await Save(db, request, decision);
                return Accepted(invoice);
            }

            case Behavior.Busy:
                http.Response.Headers.RetryAfter = FormatRetryAfter(decision.RetryAfterSeconds, settings.RetryAfterFormat);
                return Results.Problem(
                    statusCode: StatusCodes.Status429TooManyRequests,
                    title: "ERP is busy",
                    detail: $"Try again in {decision.RetryAfterSeconds} seconds.");

            case Behavior.ServerError:
                return Results.Problem(
                    statusCode: StatusCodes.Status500InternalServerError,
                    title: "ERP internal error");

            case Behavior.SaveThenError:
                await Save(db, request, decision);
                return Results.Problem(
                    statusCode: StatusCodes.Status500InternalServerError,
                    title: "ERP internal error");

            case Behavior.LateResponse:
            {
                var invoice = await Save(db, request, decision);
                try
                {
                    await Task.Delay(TimeSpan.FromSeconds(settings.LateResponseDelaySeconds), http.RequestAborted);
                }
                catch (OperationCanceledException)
                {
                    // The record stays saved: the client gave up, the ERP did not.
                    logger.LogInformation(
                        "ERP request #{Sequence} invoice={InvoiceNumber} client disconnected during late response (record kept as {ErpReference})",
                        decision.Sequence, request.InvoiceNumber, invoice.ErpReference);
                    return Results.Empty;
                }

                return Accepted(invoice);
            }

            default:
                throw new InvalidOperationException($"Unknown behavior {decision.Behavior}");
        }
    }

    private static async Task<IResult> GetInvoice(string invoiceNumber, ErpDbContext db, CancellationToken ct)
    {
        var records = await db.Invoices
            .AsNoTracking()
            .Where(i => i.InvoiceNumber == invoiceNumber)
            .OrderBy(i => i.Id)
            .Select(i => new InvoiceRecordResponse(
                i.ErpReference, i.CustomerCode, i.Amount, i.Currency, i.InvoiceDate, i.ReceivedAt))
            .ToListAsync(ct);

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

    private static async Task<ErpInvoice> Save(ErpDbContext db, CreateInvoiceRequest request, BehaviorDecision decision)
    {
        var invoice = new ErpInvoice
        {
            InvoiceNumber = request.InvoiceNumber!,
            CustomerCode = request.CustomerCode!,
            Amount = request.Amount!.Value,
            Currency = request.Currency!,
            InvoiceDate = request.InvoiceDate!.Value,
            ReceivedAt = DateTimeOffset.UtcNow,
            Behavior = decision.Behavior.ToString(),
            RequestSequence = decision.Sequence
        };

        db.Invoices.Add(invoice);
        // CancellationToken.None: once the ERP decides to save, a client disconnect must not undo it.
        await db.SaveChangesAsync(CancellationToken.None);
        return invoice;
    }

    private static IResult Accepted(ErpInvoice invoice) =>
        Results.Accepted(
            $"/api/v1/invoices/{Uri.EscapeDataString(invoice.InvoiceNumber)}",
            new InvoiceAcceptedResponse(invoice.ErpReference, invoice.InvoiceNumber, invoice.ReceivedAt));

    private static int StatusFor(Behavior behavior) => behavior switch
    {
        Behavior.Success or Behavior.LateResponse => StatusCodes.Status202Accepted,
        Behavior.Busy => StatusCodes.Status429TooManyRequests,
        _ => StatusCodes.Status500InternalServerError
    };

    internal static string FormatRetryAfter(int seconds, RetryAfterFormat format) => format switch
    {
        RetryAfterFormat.HttpDate => DateTimeOffset.UtcNow.AddSeconds(seconds).ToString("R", CultureInfo.InvariantCulture),
        _ => seconds.ToString(CultureInfo.InvariantCulture)
    };
}
