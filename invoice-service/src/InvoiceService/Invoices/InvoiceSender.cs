using InvoiceService.Data;
using InvoiceService.Erp;
using Microsoft.EntityFrameworkCore;

namespace InvoiceService.Invoices;

/// <summary>
/// Sends an invoice to the ERP once and writes the outcome as it is.
/// The attempt is counted and saved before the call, so a send that never gets an answer still shows up
/// as an attempt (status stays Başarısız until a 202 arrives).
/// Nothing stops two sends of the same invoice running at the same time (no duplicate protection on purpose);
/// the writes below only make sure the row always holds one attempt's complete result and an exact attempt count.
/// </summary>
public sealed class InvoiceSender(InvoiceDbContext db, ErpClient erp, TimeProvider time, ILogger<InvoiceSender> logger)
{
    public const string SendInProgress = "Gönderim sürüyor: ERP cevabı bekleniyor.";

    /// <summary>Sends once and returns the invoice as stored afterwards.</summary>
    public async Task<Invoice> SendAsync(Invoice invoice)
    {
        // CancellationToken.None everywhere: if the caller disconnects, the send and its result must still be recorded.
        var number = invoice.InvoiceNumber;
        var attempt = await StartAttemptAsync(invoice);

        var result = await erp.SendAsync(invoice, CancellationToken.None);

        // All result fields in one UPDATE, so a row never mixes fields of two attempts. last_error is "the error of
        // the last send": if a newer attempt started meanwhile, this older result is not written over it.
        var status = result.Accepted ? InvoiceStatus.Sent : InvoiceStatus.Failed;
        var written = await db.Invoices
            .Where(i => i.InvoiceNumber == number && i.SendAttemptCount == attempt)
            .ExecuteUpdateAsync(s => s
                .SetProperty(i => i.Status, status)
                .SetProperty(i => i.ErpReference, result.ErpReference)
                .SetProperty(i => i.LastError, result.Error)
                .SetProperty(i => i.UpdatedAt, time.GetUtcNow()), CancellationToken.None);

        logger.LogInformation(
            "ERP send invoice={InvoiceNumber} attempt={Attempt} result={Status} http={HttpStatus} erpReference={ErpReference} " +
            "elapsed={ElapsedMs}ms error={Error}{Superseded}",
            number, attempt, status, result.HttpStatus?.ToString() ?? "-", result.ErpReference ?? "-",
            (long)result.Elapsed.TotalMilliseconds, result.Error ?? "-",
            written == 0 ? " (not written: a newer attempt of this invoice started meanwhile)" : "");

        return await db.Invoices.AsNoTracking().SingleAsync(i => i.InvoiceNumber == number, CancellationToken.None);
    }

    /// <summary>Counts the attempt and marks it in progress before the ERP call; returns this attempt's number.</summary>
    private async Task<int> StartAttemptAsync(Invoice invoice)
    {
        var now = time.GetUtcNow();

        if (db.Entry(invoice).State == EntityState.Added)
        {
            // First send: the insert itself is attempt 1.
            invoice.SendAttemptCount = 1;
            invoice.Status = InvoiceStatus.Failed;
            invoice.ErpReference = null;
            invoice.LastError = SendInProgress;
            invoice.UpdatedAt = now;
            await db.SaveChangesAsync(CancellationToken.None);
            return 1;
        }

        // Resend: increment in the database, not in memory, so concurrent sends each get their own number
        // and none of them is lost from the count.
        var attempts = await db.Database.SqlQuery<int>($"""
            UPDATE invoices
            SET send_attempt_count = send_attempt_count + 1,
                status = {InvoiceStatus.Failed},
                erp_reference = NULL,
                last_error = {SendInProgress},
                updated_at = {now}
            WHERE invoice_number = {invoice.InvoiceNumber}
            RETURNING send_attempt_count AS "Value"
            """).ToListAsync(CancellationToken.None);
        return attempts.Single();
    }
}
