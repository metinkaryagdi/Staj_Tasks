using ErpSimulator.Application.Abstractions;
using ErpSimulator.Application.Simulation;
using ErpSimulator.Domain.Invoices;

namespace ErpSimulator.Application.Invoices;

public enum CancelOutcome
{
    /// <summary>The ERP has no record of the invoice number (404); no behavior was drawn.</summary>
    NotFound,

    /// <summary>The ERP rejected the invoice (409); no behavior was drawn.</summary>
    Rejected,

    /// <summary>Already cancelled: 202 with the existing cancellation, nothing saved; no behavior was drawn.</summary>
    Duplicate,

    /// <summary>A behavior was drawn and carried out; <see cref="CancelInvoiceResult.Decision"/> says which.</summary>
    Decided
}

/// <param name="Cancellation">The saved cancellation (Decided and saved), or the existing one (Duplicate).</param>
/// <param name="ClientGone">LateResponse only: the client disconnected during the delay (the cancellation stays saved).</param>
public sealed record CancelInvoiceResult(
    CancelOutcome Outcome, ErpCancellation? Cancellation = null, BehaviorDecision? Decision = null, bool ClientGone = false);

/// <summary>
/// One cancellation request. Only a recorded, not rejected invoice is cancelled, and only once: requests for the same
/// invoice number wait for each other (a lock held until the cancellation is committed), so a repeated request always
/// finds the first one's record. A new cancellation goes through the same seeded behaviors as an invoice POST.
/// </summary>
public sealed class CancelInvoiceHandler(
    IErpInvoiceStore invoices, InvoiceLookup lookup, BehaviorSelector selector, IOptions<SimulatorOptions> options,
    TimeProvider time, ILoggerFactory loggerFactory)
{
    private readonly ILogger _logger = loggerFactory.CreateLogger("ErpSimulator.Invoices");

    public async Task<CancelInvoiceResult> HandleAsync(string invoiceNumber, CancellationToken requestAborted)
    {
        await using var invoiceLock = await invoices.LockInvoiceNumberAsync(invoiceNumber);

        var existing = await invoices.FindCancellationAsync(invoiceNumber, CancellationToken.None);
        if (existing is not null)
        {
            _logger.LogInformation(
                "ERP cancel invoice={InvoiceNumber} behavior=Duplicate status=202 cancelReference={CancelReference} (already cancelled, not saved again)",
                invoiceNumber, existing.CancelReference);
            return new CancelInvoiceResult(CancelOutcome.Duplicate, existing);
        }

        var found = await lookup.FindAsync(invoiceNumber, CancellationToken.None);
        if (found.Records.Count == 0)
        {
            _logger.LogInformation("ERP cancel invoice={InvoiceNumber} status=404 reason=notRecorded", invoiceNumber);
            return new CancelInvoiceResult(CancelOutcome.NotFound);
        }

        if (found.Decision.Kind == DecisionKind.Rejected)
        {
            _logger.LogInformation("ERP cancel invoice={InvoiceNumber} status=409 reason=rejected", invoiceNumber);
            return new CancelInvoiceResult(CancelOutcome.Rejected);
        }

        var decision = selector.Next();
        _logger.LogInformation(
            "ERP cancel request #{Sequence} invoice={InvoiceNumber} behavior={Behavior}",
            decision.Sequence, invoiceNumber, decision.Behavior);

        switch (decision.Behavior)
        {
            case Behavior.Busy:
            case Behavior.ServerError:
                return new CancelInvoiceResult(CancelOutcome.Decided, Decision: decision);

            case Behavior.Success:
            case Behavior.SaveThenError:
                return new CancelInvoiceResult(CancelOutcome.Decided, await Save(invoiceNumber), decision);

            case Behavior.LateResponse:
            {
                // Saved (and the lock released) before the delay, like a late invoice answer.
                var cancellation = await Save(invoiceNumber);
                try
                {
                    await Task.Delay(TimeSpan.FromSeconds(options.Value.LateResponseDelaySeconds), requestAborted);
                }
                catch (OperationCanceledException)
                {
                    _logger.LogInformation(
                        "ERP cancel request #{Sequence} invoice={InvoiceNumber} client disconnected during late response (cancellation kept as {CancelReference})",
                        decision.Sequence, invoiceNumber, cancellation.CancelReference);
                    return new CancelInvoiceResult(CancelOutcome.Decided, cancellation, decision, ClientGone: true);
                }

                return new CancelInvoiceResult(CancelOutcome.Decided, cancellation, decision);
            }

            default:
                throw new InvalidOperationException($"Unknown behavior {decision.Behavior}");
        }
    }

    private async Task<ErpCancellation> Save(string invoiceNumber)
    {
        var cancellation = new ErpCancellation { InvoiceNumber = invoiceNumber, CancelledAt = time.GetUtcNow() };
        await invoices.SaveCancellationAsync(cancellation);
        return cancellation;
    }
}
