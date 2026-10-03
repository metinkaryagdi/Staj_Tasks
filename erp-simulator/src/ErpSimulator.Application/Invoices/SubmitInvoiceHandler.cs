using ErpSimulator.Application.Abstractions;
using ErpSimulator.Application.Simulation;
using ErpSimulator.Application.Webhooks;
using ErpSimulator.Domain.Invoices;

namespace ErpSimulator.Application.Invoices;

public enum SubmitOutcome
{
    /// <summary>The request is invalid (400); no behavior was drawn.</summary>
    Invalid,

    /// <summary>IdempotentInvoices: already recorded with the same content (202 with the existing reference).</summary>
    Duplicate,

    /// <summary>IdempotentInvoices: already recorded with different content (409).</summary>
    Conflict,

    /// <summary>A behavior was drawn and carried out; <see cref="SubmitInvoiceResult.Decision"/> says which.</summary>
    Decided
}

/// <param name="Invoice">The saved record (Decided and saved), or the existing one (Duplicate, Conflict).</param>
/// <param name="ClientGone">LateResponse only: the client disconnected during the delay (the record stays saved).</param>
public sealed record SubmitInvoiceResult(
    SubmitOutcome Outcome, Dictionary<string, string[]>? Errors = null, ErpInvoice? Invoice = null,
    BehaviorDecision? Decision = null, bool ClientGone = false);

/// <summary>
/// One POST to the ERP: picks a seeded behavior and carries it out (saves or not, answers late or not). Turning the
/// result into an HTTP answer is the endpoint's job.
/// </summary>
public sealed class SubmitInvoiceHandler(
    IErpInvoiceStore invoices, BehaviorSelector selector, WebhookPlanner planner, IOptions<SimulatorOptions> options,
    ILoggerFactory loggerFactory)
{
    private readonly ILogger _logger = loggerFactory.CreateLogger("ErpSimulator.Invoices");

    public async Task<SubmitInvoiceResult> HandleAsync(CreateInvoiceRequest request, CancellationToken requestAborted)
    {
        // Invalid requests are rejected before a behavior is drawn so they don't shift the seeded sequence.
        var errors = request.Validate();
        if (errors.Count > 0)
        {
            _logger.LogWarning("Rejected invalid invoice request invoice={InvoiceNumber}", request.InvoiceNumber);
            return new SubmitInvoiceResult(SubmitOutcome.Invalid, errors);
        }

        var settings = options.Value;

        // With IdempotentInvoices on, requests for the same invoice number wait for each other (a lock held until the
        // record is committed), so a second request always sees the first one's record, even if saving it was slow.
        await using var invoiceLock = settings.IdempotentInvoices
            ? await invoices.LockInvoiceNumberAsync(request.InvoiceNumber!)
            : null;
        if (invoiceLock is not null)
        {
            var existing = await invoices.FindFirstAsync(request.InvoiceNumber!);
            if (existing is not null)
                return Duplicate(existing, request);
        }

        var decision = selector.Next();

        if (decision.Behavior == Behavior.Busy)
        {
            _logger.LogInformation(
                "ERP request #{Sequence} invoice={InvoiceNumber} behavior={Behavior} status=429 retryAfter={RetryAfter}s",
                decision.Sequence, request.InvoiceNumber, decision.Behavior, decision.RetryAfterSeconds);
        }
        else
        {
            _logger.LogInformation(
                "ERP request #{Sequence} invoice={InvoiceNumber} behavior={Behavior} status={Status}",
                decision.Sequence, request.InvoiceNumber, decision.Behavior, StatusFor(decision.Behavior));
        }

        switch (decision.Behavior)
        {
            case Behavior.Success:
                return Decided(decision, await Save(request, decision));

            case Behavior.Busy:
            case Behavior.ServerError:
                return Decided(decision);

            case Behavior.SaveThenError:
                return Decided(decision, await Save(request, decision));

            case Behavior.LateResponse:
            {
                // Save commits (and releases the invoice number lock) before the delay, like a real ERP that answers late.
                var invoice = await Save(request, decision);
                try
                {
                    await Task.Delay(TimeSpan.FromSeconds(settings.LateResponseDelaySeconds), requestAborted);
                }
                catch (OperationCanceledException)
                {
                    // The record stays saved: the client gave up, the ERP did not.
                    _logger.LogInformation(
                        "ERP request #{Sequence} invoice={InvoiceNumber} client disconnected during late response (record kept as {ErpReference})",
                        decision.Sequence, request.InvoiceNumber, invoice.ErpReference);
                    return Decided(decision, invoice, clientGone: true);
                }

                return Decided(decision, invoice);
            }

            default:
                throw new InvalidOperationException($"Unknown behavior {decision.Behavior}");
        }
    }

    private static SubmitInvoiceResult Decided(BehaviorDecision decision, ErpInvoice? invoice = null, bool clientGone = false) =>
        new(SubmitOutcome.Decided, Invoice: invoice, Decision: decision, ClientGone: clientGone);

    /// <summary>Saves the record and plans its events (webhook_deliveries) in one transaction.</summary>
    private async Task<ErpInvoice> Save(CreateInvoiceRequest request, BehaviorDecision decision)
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

        await invoices.SaveAsync(invoice, saved => planner.Plan(saved, saved.ReceivedAt));
        return invoice;
    }

    private SubmitInvoiceResult Duplicate(ErpInvoice existing, CreateInvoiceRequest request)
    {
        var sameContent = existing.CustomerCode == request.CustomerCode
                          && existing.Amount == request.Amount
                          && existing.Currency == request.Currency
                          && existing.InvoiceDate == request.InvoiceDate;

        if (!sameContent)
        {
            _logger.LogInformation(
                "ERP request invoice={InvoiceNumber} behavior=Conflict status=409 existing={ErpReference}",
                request.InvoiceNumber, existing.ErpReference);
            return new SubmitInvoiceResult(SubmitOutcome.Conflict, Invoice: existing);
        }

        _logger.LogInformation(
            "ERP request invoice={InvoiceNumber} behavior=Duplicate status=202 erpReference={ErpReference} (already recorded, not saved again)",
            request.InvoiceNumber, existing.ErpReference);
        return new SubmitInvoiceResult(SubmitOutcome.Duplicate, Invoice: existing);
    }

    private static int StatusFor(Behavior behavior) => behavior switch
    {
        Behavior.Success or Behavior.LateResponse => 202,
        Behavior.Busy => 429,
        _ => 500
    };
}
