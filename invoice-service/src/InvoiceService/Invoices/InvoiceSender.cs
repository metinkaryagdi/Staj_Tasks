using InvoiceService.Data;
using InvoiceService.Erp;

namespace InvoiceService.Invoices;

/// <summary>
/// Sends an invoice to the ERP once and writes the outcome as it is.
/// The attempt is counted and saved before the call, so a send that never gets an answer still shows up
/// as an attempt (status stays Başarısız until a 202 arrives).
/// </summary>
public sealed class InvoiceSender(InvoiceDbContext db, ErpClient erp, TimeProvider time, ILogger<InvoiceSender> logger)
{
    public const string SendInProgress = "Gönderim sürüyor: ERP cevabı bekleniyor.";

    public async Task SendAsync(Invoice invoice)
    {
        // CancellationToken.None everywhere: if the caller disconnects, the send and its result must still be recorded.
        invoice.SendAttemptCount++;
        invoice.Status = InvoiceStatus.Failed;
        invoice.ErpReference = null;
        invoice.LastError = SendInProgress;
        invoice.UpdatedAt = time.GetUtcNow();
        await db.SaveChangesAsync(CancellationToken.None);

        var result = await erp.SendAsync(invoice, CancellationToken.None);

        invoice.Status = result.Accepted ? InvoiceStatus.Sent : InvoiceStatus.Failed;
        invoice.ErpReference = result.ErpReference;
        invoice.LastError = result.Error;
        invoice.UpdatedAt = time.GetUtcNow();
        await db.SaveChangesAsync(CancellationToken.None);

        logger.LogInformation(
            "ERP send invoice={InvoiceNumber} attempt={Attempt} result={Status} http={HttpStatus} erpReference={ErpReference} " +
            "elapsed={ElapsedMs}ms error={Error}",
            invoice.InvoiceNumber, invoice.SendAttemptCount, invoice.Status, result.HttpStatus?.ToString() ?? "-",
            result.ErpReference ?? "-", (long)result.Elapsed.TotalMilliseconds, result.Error ?? "-");
    }
}
