using InvoiceService.Application.Abstractions;
using InvoiceService.Domain.Invoices;

namespace InvoiceService.Application.Outbox;

/// <summary>Which way an attempt went. Written to the log as <c>check=</c>.</summary>
public enum SendPath
{
    /// <summary>First attempt: POSTed without asking.</summary>
    First,

    /// <summary>The ERP already had the invoice: not sent again.</summary>
    Found,

    /// <summary>The ERP said it does not have the invoice (404): POSTed (or, when only asking, counted as not there).</summary>
    NotFound,

    /// <summary>The ERP could not be asked: nothing sent.</summary>
    Unknown,

    /// <summary>The entry was no longer held with this claim: nothing sent, nothing to write.</summary>
    NotHeld
}

/// <summary>The result of one attempt and the way it went.</summary>
public sealed record SendAttempt(ErpSendResult Result, SendPath Path)
{
    /// <summary>The path as it appears in the log (first, found, notFound, unknown, notHeld).</summary>
    public string Check => Path switch
    {
        SendPath.First => "first",
        SendPath.Found => "found",
        SendPath.NotFound => "notFound",
        SendPath.Unknown => "unknown",
        _ => "notHeld"
    };
}

/// <summary>
/// Makes one attempt to get an invoice to the ERP: the first time it POSTs; later it asks the ERP first and POSTs only if
/// the ERP clearly does not have the invoice. Does not retry and writes nothing.
/// </summary>
public sealed class ErpSendStrategy(IErpGateway erp, IOutboxStore outbox, TimeProvider time)
{
    /// <summary>
    /// Asks the ERP whether it has the invoice, without sending it. Found -> accepted with the ERP's reference;
    /// not found -> failed with <paramref name="lastError"/>; ERP cannot be asked -> failed, the error says so.
    /// </summary>
    public async Task<SendAttempt> ConfirmAsync(Invoice invoice, string? lastError)
    {
        var lookup = await erp.FindAsync(invoice.InvoiceNumber, CancellationToken.None);
        return lookup.Lookup switch
        {
            ErpLookup.Found => new(new ErpSendResult(true, lookup.ErpReference, lookup.HttpStatus, null, lookup.Elapsed), SendPath.Found),
            ErpLookup.NotFound => new(new ErpSendResult(false, null, lookup.HttpStatus, lastError, lookup.Elapsed), SendPath.NotFound),
            _ => new(new ErpSendResult(false, null, null, $"{lastError} Son durum ERP'ye sorulamadı: {lookup.Error}", lookup.Elapsed), SendPath.Unknown)
        };
    }

    /// <summary>One attempt. Nothing is POSTed if the entry is no longer held with this claim (<see cref="SendPath.NotHeld"/>).</summary>
    public async Task<SendAttempt> SendOnceAsync(Invoice invoice, ClaimedEntry entry)
    {
        // send_attempt_count already includes this attempt and is never reset: 1 means the ERP cannot have the invoice yet.
        if (invoice.SendAttemptCount <= 1)
        {
            return await StillHeldAsync(entry)
                ? new(await erp.SendAsync(invoice, CancellationToken.None), SendPath.First)
                : new(new ErpSendResult(false, null, null, null, TimeSpan.Zero), SendPath.NotHeld);
        }

        var lookup = await erp.FindAsync(invoice.InvoiceNumber, CancellationToken.None);
        if (lookup.Lookup == ErpLookup.NotFound && !await StillHeldAsync(entry))
            return new(new ErpSendResult(false, null, null, null, lookup.Elapsed), SendPath.NotHeld);

        return lookup.Lookup switch
        {
            ErpLookup.Found => new(new ErpSendResult(true, lookup.ErpReference, lookup.HttpStatus, null, lookup.Elapsed), SendPath.Found),
            ErpLookup.NotFound => new(await erp.SendAsync(invoice, CancellationToken.None), SendPath.NotFound),
            // No answer the ERP's state can be read from: treated like a timeout (backoff), never as "not there".
            _ => new(new ErpSendResult(false, null, null, lookup.Error, lookup.Elapsed), SendPath.Unknown)
        };
    }

    /// <summary>Whether the entry still carries this claim and its lock has not run out.</summary>
    private Task<bool> StillHeldAsync(ClaimedEntry entry) =>
        outbox.IsHeldAsync(entry.Id, entry.ClaimToken, time.GetUtcNow(), CancellationToken.None);
}
