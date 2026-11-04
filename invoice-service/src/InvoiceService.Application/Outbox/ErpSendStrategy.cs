using InvoiceService.Application.Abstractions;
using InvoiceService.Application.Metrics;
using InvoiceService.Application.Tracing;
using InvoiceService.Domain.Invoices;
using InvoiceService.Domain.Outbox;

namespace InvoiceService.Application.Outbox;

/// <summary>Which way an attempt went. Written to the log as <c>check=</c>.</summary>
public enum SendPath
{
    /// <summary>First attempt: POSTed without asking.</summary>
    First,

    /// <summary>The ERP already had the invoice: not sent again.</summary>
    Found,

    /// <summary>The ERP said it does not have the invoice (404): POSTed (or, when only asking, counted as not
    /// there).</summary>
    NotFound,

    /// <summary>The ERP could not be asked: nothing sent.</summary>
    Unknown,

    /// <summary>The invoice has a cancellation and the ERP does not have the invoice: nothing sent, neither the invoice
    /// nor its cancellation.</summary>
    InvoiceNotFound,

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
        SendPath.InvoiceNotFound => "invoiceNotFound",
        _ => "notHeld"
    };
}

/// <summary>
/// Makes one attempt to get an invoice to the ERP: the first time it POSTs; later, or once the invoice has a cancellation, it
/// asks the ERP first. It POSTs only if the ERP clearly does not have the invoice and the invoice has no cancellation. Every
/// POST waits for its turn (<see cref="IErpSendPacer"/>).
/// Does not retry and writes nothing.
/// </summary>
public sealed class ErpSendStrategy(
    IErpGateway erp, IErpSendPacer pacer, IOutboxStore outbox, TimeProvider time, InvoiceMetrics metrics)
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

    /// <summary>
    /// One attempt. Nothing is POSTed if the entry is no longer held with this claim
    /// (<see cref="SendPath.NotHeld"/>).
    /// </summary>
    public async Task<SendAttempt> SendOnceAsync(Invoice invoice, ClaimedEntry entry)
    {
        // send_attempt_count already includes this attempt and is never reset: 1 means the ERP cannot have the
        // invoice yet.
        // The turn is waited for before the claim is checked, so the check is the last thing before the POST.
        // A cancellation can arrive during the wait, so it is checked again after it.
        var cancelRequested = await CancelRequestedAsync(invoice);
        if (invoice.SendAttemptCount <= 1 && !cancelRequested)
        {
            await WaitForTurnAsync();
            if (!await StillHeldAsync(entry))
                return new(new ErpSendResult(false, null, null, null, TimeSpan.Zero), SendPath.NotHeld);

            cancelRequested = await CancelRequestedAsync(invoice);
            if (!cancelRequested)
                return new(await PostAsync(invoice), SendPath.First);
        }

        var lookup = await erp.FindAsync(invoice.InvoiceNumber, CancellationToken.None);
        if (lookup.Lookup == ErpLookup.NotFound && cancelRequested)
            return new(new ErpSendResult(false, null, lookup.HttpStatus, null, lookup.Elapsed), SendPath.InvoiceNotFound);

        if (lookup.Lookup == ErpLookup.NotFound)
        {
            await WaitForTurnAsync();
            if (!await StillHeldAsync(entry))
                return new(new ErpSendResult(false, null, null, null, lookup.Elapsed), SendPath.NotHeld);
            if (await CancelRequestedAsync(invoice))
                return new(new ErpSendResult(false, null, lookup.HttpStatus, null, lookup.Elapsed), SendPath.InvoiceNotFound);
        }

        return lookup.Lookup switch
        {
            ErpLookup.Found => new(new ErpSendResult(true, lookup.ErpReference, lookup.HttpStatus, null, lookup.Elapsed), SendPath.Found),
            ErpLookup.NotFound => new(await PostAsync(invoice), SendPath.NotFound),
            // No answer the ERP's state can be read from: treated like a timeout (backoff), never as "not there".
            _ => new(new ErpSendResult(false, null, null, lookup.Error, lookup.Elapsed, NoAnswer: lookup.NoAnswer), SendPath.Unknown)
        };
    }

    /// <summary>
    /// One cancellation attempt. The ERP is always asked first: already cancelled -> accepted with its cancel reference
    /// (<see cref="SendPath.Found"/>: an earlier attempt got there without us being told); invoice not there -> failed
    /// with a 404, nothing to cancel; invoice there but not cancelled -> the cancellation is POSTed once it is this
    /// entry's turn and the entry is still held (<see cref="SendPath.NotFound"/>).
    /// </summary>
    public async Task<SendAttempt> CancelOnceAsync(ClaimedEntry entry)
    {
        var lookup = await erp.FindAsync(entry.InvoiceNumber, CancellationToken.None);
        if (lookup.Lookup == ErpLookup.Found && lookup.CancelReference is null)
        {
            await WaitForTurnAsync();
            return await StillHeldAsync(entry)
                ? new(await erp.CancelAsync(entry.InvoiceNumber, CancellationToken.None), SendPath.NotFound)
                : new(new ErpSendResult(false, null, null, null, lookup.Elapsed), SendPath.NotHeld);
        }

        return CancelLookupOutcome(lookup, lastError: null);
    }

    /// <summary>
    /// Asks the ERP whether it has cancelled the invoice, without sending. Cancelled -> accepted; anything else -> failed
    /// with <paramref name="lastError"/> (or why the ERP could not be asked).
    /// </summary>
    public async Task<SendAttempt> ConfirmCancelAsync(string invoiceNumber, string? lastError)
    {
        var lookup = await erp.FindAsync(invoiceNumber, CancellationToken.None);
        if (lookup.Lookup == ErpLookup.Found && lookup.CancelReference is null)
            return new(new ErpSendResult(false, null, lookup.HttpStatus, lastError, lookup.Elapsed), SendPath.NotFound);
        var outcome = CancelLookupOutcome(lookup, lastError);
        return outcome.Path == SendPath.Unknown
            ? outcome with { Result = outcome.Result with { Error = $"{lastError} Son durum ERP'ye sorulamadı: {lookup.Error}" } }
            : outcome;
    }

    private static SendAttempt CancelLookupOutcome(ErpLookupResult lookup, string? lastError) => lookup.Lookup switch
    {
        ErpLookup.Found => new(new ErpSendResult(true, lookup.CancelReference, lookup.HttpStatus, null, lookup.Elapsed), SendPath.Found),
        // A 404 is final under RetryPolicy: an invoice the ERP does not have cannot be cancelled there.
        ErpLookup.NotFound => new(new ErpSendResult(false, null, lookup.HttpStatus,
            "ERP faturayı bilmiyor; iptal edilecek kayıt yok, iptal gönderilmedi.", lookup.Elapsed), SendPath.InvoiceNotFound),
        _ => new(new ErpSendResult(false, null, null, lookup.Error ?? lastError, lookup.Elapsed, NoAnswer: lookup.NoAnswer), SendPath.Unknown)
    };

    private async Task<bool> CancelRequestedAsync(Invoice invoice) =>
        await outbox.FindAsync(invoice.InvoiceNumber, CancellationToken.None, OutboxKind.Cancel) is not null;

    private async Task WaitForTurnAsync()
    {
        using var span = InvoiceTracing.Source.StartActivity("erp.pace_wait");
        var started = time.GetTimestamp();
        await pacer.WaitForTurnAsync(CancellationToken.None);
        var waited = time.GetElapsedTime(started);
        metrics.PaceWait(waited);
        span?.SetTag("erp.pace_wait_seconds", waited.TotalSeconds);
    }

    private async Task<ErpSendResult> PostAsync(Invoice invoice)
    {
        var result = await erp.SendAsync(invoice, CancellationToken.None);
        metrics.SendDuration(result.Elapsed);
        return result;
    }

    /// <summary>Whether the entry still carries this claim and its lock has not run out.</summary>
    private Task<bool> StillHeldAsync(ClaimedEntry entry) =>
        outbox.IsHeldAsync(entry.Id, entry.ClaimToken, time.GetUtcNow(), CancellationToken.None);
}
