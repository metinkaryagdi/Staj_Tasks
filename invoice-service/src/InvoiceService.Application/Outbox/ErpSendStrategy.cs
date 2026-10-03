using InvoiceService.Application.Abstractions;
using InvoiceService.Domain.Invoices;

namespace InvoiceService.Application.Outbox;

/// <summary>
/// How one attempt reaches the ERP: POST directly the first time, otherwise ask the ERP first and POST only if it
/// clearly does not have the invoice (see <see cref="OutboxProcessor.SendAsync"/> for why). Does no retrying and writes
/// nothing: the caller decides what the result means.
/// </summary>
public sealed class ErpSendStrategy(IErpGateway erp, IOutboxStore outbox, TimeProvider time)
{
    /// <summary><c>Check</c> value when the entry was no longer held at the moment of sending: nothing sent, nothing written.</summary>
    public const string NotHeld = "notHeld";

    /// <summary>
    /// Asks the ERP whether it has the invoice, without sending it. Found -> accepted with the ERP's reference;
    /// not found -> failed with <paramref name="lastError"/>; ERP cannot be asked -> failed, the error says so.
    /// </summary>
    public async Task<(ErpSendResult Result, string Check)> ConfirmAsync(Invoice invoice, string? lastError)
    {
        var lookup = await erp.FindAsync(invoice.InvoiceNumber, CancellationToken.None);
        return lookup.Lookup switch
        {
            ErpLookup.Found => (new ErpSendResult(true, lookup.ErpReference, lookup.HttpStatus, null, lookup.Elapsed), "found"),
            ErpLookup.NotFound => (new ErpSendResult(false, null, lookup.HttpStatus, lastError, lookup.Elapsed), "notFound"),
            _ => (new ErpSendResult(false, null, null, $"{lastError} Son durum ERP'ye sorulamadı: {lookup.Error}", lookup.Elapsed), "unknown")
        };
    }

    /// <summary>
    /// One attempt: POST directly the first time; otherwise ask the ERP first.
    /// Right before a POST the entry must still be held with this claim and its lock must not have run out; otherwise
    /// nothing is sent (<see cref="NotHeld"/>): a worker that stalled past its lock must not send what another worker
    /// may be sending already.
    /// <c>Check</c> says which path was taken, for the log: first, found, notFound, unknown or notHeld.
    /// </summary>
    public async Task<(ErpSendResult Result, string Check)> SendOnceAsync(Invoice invoice, ClaimedEntry entry)
    {
        // send_attempt_count is counted per invoice for its whole life (a resend does not reset it) and already
        // includes this attempt, so 1 means nothing was ever sent before and the ERP cannot have the invoice.
        if (invoice.SendAttemptCount <= 1)
        {
            return await StillHeldAsync(entry)
                ? (await erp.SendAsync(invoice, CancellationToken.None), "first")
                : (new ErpSendResult(false, null, null, null, TimeSpan.Zero), NotHeld);
        }

        var lookup = await erp.FindAsync(invoice.InvoiceNumber, CancellationToken.None);
        if (lookup.Lookup == ErpLookup.NotFound && !await StillHeldAsync(entry))
            return (new ErpSendResult(false, null, null, null, lookup.Elapsed), NotHeld);

        return lookup.Lookup switch
        {
            ErpLookup.Found => (new ErpSendResult(true, lookup.ErpReference, lookup.HttpStatus, null, lookup.Elapsed), "found"),
            ErpLookup.NotFound => (await erp.SendAsync(invoice, CancellationToken.None), "notFound"),
            // No answer the ERP's state can be read from: treated like a timeout (backoff), never as "not there".
            _ => (new ErpSendResult(false, null, null, lookup.Error, lookup.Elapsed), "unknown")
        };
    }

    /// <summary>Whether the entry still carries this claim and its lock has not run out.</summary>
    private Task<bool> StillHeldAsync(ClaimedEntry entry) =>
        outbox.IsHeldAsync(entry.Id, entry.ClaimToken, time.GetUtcNow(), CancellationToken.None);
}
