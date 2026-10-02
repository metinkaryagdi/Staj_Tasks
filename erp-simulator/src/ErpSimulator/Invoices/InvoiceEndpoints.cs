using System.Globalization;
using ErpSimulator.Data;
using ErpSimulator.Simulation;
using ErpSimulator.Webhooks;
using Microsoft.EntityFrameworkCore;
using Microsoft.EntityFrameworkCore.Storage;
using Microsoft.Extensions.Options;

namespace ErpSimulator.Invoices;

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
        ErpDbContext db,
        BehaviorSelector selector,
        WebhookPlanner planner,
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

        var settings = options.Value;

        // With IdempotentInvoices on, requests for the same invoice number wait for each other (a lock held until the
        // record is committed), so a second request always sees the first one's record, even if saving it was slow.
        await using var invoiceLock = settings.IdempotentInvoices
            ? await LockInvoiceNumber(db, request.InvoiceNumber!)
            : null;
        if (invoiceLock is not null)
        {
            var existing = await db.Invoices
                .AsNoTracking()
                .Where(i => i.InvoiceNumber == request.InvoiceNumber)
                .OrderBy(i => i.Id)
                .FirstOrDefaultAsync(CancellationToken.None);
            if (existing is not null)
                return Duplicate(existing, request, logger);
        }

        var decision = selector.Next();

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
                var invoice = await Save(db, planner, request, decision);
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
                await Save(db, planner, request, decision);
                return Results.Problem(
                    statusCode: StatusCodes.Status500InternalServerError,
                    title: "ERP internal error");

            case Behavior.LateResponse:
            {
                // Save commits (and releases the invoice number lock) before the delay, like a real ERP that answers late.
                var invoice = await Save(db, planner, request, decision);
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

    /// <summary>
    /// Saves the record and plans its events (webhook_deliveries) in one transaction: a saved invoice always gets its
    /// events, and no event exists for an invoice that was not saved. The events need the ERP reference, which the
    /// database generates on insert, so the record is inserted first.
    /// </summary>
    private static async Task<ErpInvoice> Save(
        ErpDbContext db, WebhookPlanner planner, CreateInvoiceRequest request, BehaviorDecision decision)
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

        // With IdempotentInvoices on, the invoice number lock's transaction is already open; it is committed here too.
        var transaction = db.Database.CurrentTransaction ?? await db.Database.BeginTransactionAsync(CancellationToken.None);

        db.Invoices.Add(invoice);
        // CancellationToken.None: once the ERP decides to save, a client disconnect must not undo it.
        await db.SaveChangesAsync(CancellationToken.None);
        db.WebhookDeliveries.AddRange(planner.Plan(invoice, invoice.ReceivedAt));
        await db.SaveChangesAsync(CancellationToken.None);

        await transaction.CommitAsync(CancellationToken.None);
        await transaction.DisposeAsync();
        return invoice;
    }

    /// <summary>
    /// Starts a transaction holding a lock on the invoice number until it ends (commit in Save, otherwise rollback
    /// when the request finishes). A lock instead of a unique index: existing duplicates stay valid and the setting
    /// can be switched off again.
    /// </summary>
    private static async Task<IDbContextTransaction> LockInvoiceNumber(ErpDbContext db, string invoiceNumber)
    {
        var transaction = await db.Database.BeginTransactionAsync(CancellationToken.None);
        await db.Database.ExecuteSqlInterpolatedAsync(
            $"SELECT pg_advisory_xact_lock(hashtextextended({invoiceNumber}, 0))", CancellationToken.None);
        return transaction;
    }

    private static IResult Duplicate(ErpInvoice existing, CreateInvoiceRequest request, ILogger logger)
    {
        var sameContent = existing.CustomerCode == request.CustomerCode
                          && existing.Amount == request.Amount
                          && existing.Currency == request.Currency
                          && existing.InvoiceDate == request.InvoiceDate;

        if (!sameContent)
        {
            logger.LogInformation(
                "ERP request invoice={InvoiceNumber} behavior=Conflict status=409 existing={ErpReference}",
                request.InvoiceNumber, existing.ErpReference);
            return Results.Problem(
                statusCode: StatusCodes.Status409Conflict,
                title: "Invoice number already used",
                detail: $"Invoice '{request.InvoiceNumber}' is already recorded as {existing.ErpReference} with different content.");
        }

        logger.LogInformation(
            "ERP request invoice={InvoiceNumber} behavior=Duplicate status=202 erpReference={ErpReference} (already recorded, not saved again)",
            request.InvoiceNumber, existing.ErpReference);
        return Accepted(existing);
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
