using InvoiceService.Application.Abstractions;
using InvoiceService.Application.Webhooks;
using InvoiceService.Domain.Invoices;
using InvoiceService.Domain.Outbox;

namespace InvoiceService.Application.Outbox;

/// <summary>
/// Writes the outcome of an attempt to erp_outbox and invoices in one transaction, and applies the ERP events that were
/// waiting for the invoice when it becomes Gönderildi. A cancellation's outcome is written to its outbox entry only: the
/// ERP's cancellation event changes the invoice's status. When nothing goes to the ERP there is no such event, so the
/// invoice is made İptal Edildi here.
/// </summary>
public sealed class OutboxOutcomeWriter(
    IUnitOfWork unitOfWork, IOutboxStore outbox, IInvoiceStore invoices, WebhookEventProcessor events)
{
    private const string NotSent = "Fatura iptal edildi, ERP'ye gönderilmedi.";

    /// <summary>
    /// Returns false when the entry no longer carries this claim: nothing was written (see
    /// <see cref="IOutboxStore.WriteOutcomeAsync"/>).
    /// </summary>
    public async Task<bool> WriteAsync(ClaimedEntry entry, RetryDecision decision, ErpSendResult result, DateTimeOffset now)
    {
        if (decision.Outcome == SendOutcome.Cancelled)
            return await WriteCancelledAsync(entry, now);

        var (invoiceStatus, outboxStatus) = decision.Outcome switch
        {
            SendOutcome.Sent => (InvoiceStatus.Sent, OutboxStatus.Completed),
            SendOutcome.Failed => (InvoiceStatus.Failed, OutboxStatus.Failed),
            _ => (InvoiceStatus.Pending, OutboxStatus.Pending)
        };
        var done = decision.Outcome != SendOutcome.Retry;
        DateTimeOffset? processedAt = done ? now : null;
        var nextAttemptAt = done ? now : now + decision.Delay;

        await using var transaction = await unitOfWork.BeginAsync(CancellationToken.None);

        // Written only if the entry still carries this claim; otherwise another worker took it and this outcome is
        // dropped.
        var owned = await outbox.WriteOutcomeAsync(
            entry.Id, entry.ClaimToken, outboxStatus, result.Error, nextAttemptAt, processedAt, CancellationToken.None);

        if (owned && entry.IsCancel)
        {
            await transaction.CommitAsync(CancellationToken.None);
        }
        else if (owned)
        {
            await invoices.WriteSendOutcomeAsync(
                entry.InvoiceNumber, invoiceStatus, result.ErpReference, result.Error, now, CancellationToken.None);

            // Events that arrived before the invoice was Gönderildi are applied now. The UPDATE above holds the
            // invoice's row lock, so an event arriving at this moment waits for this commit.
            if (invoiceStatus == InvoiceStatus.Sent)
                await events.ApplyWaitingAsync(entry.InvoiceNumber, now, CancellationToken.None);

            await transaction.CommitAsync(CancellationToken.None);
        }

        return owned;
    }

    /// <summary>
    /// The ERP does not have the invoice and nothing was sent: the cancellation is done and the invoice İptal Edildi. A send
    /// entry ends Başarısız, not Tamamlandı: the invoice never reached the ERP.
    /// </summary>
    private async Task<bool> WriteCancelledAsync(ClaimedEntry entry, DateTimeOffset now)
    {
        await using var transaction = await unitOfWork.BeginAsync(CancellationToken.None);

        var owned = await outbox.WriteOutcomeAsync(
            entry.Id, entry.ClaimToken, entry.IsCancel ? OutboxStatus.Completed : OutboxStatus.Failed,
            entry.IsCancel ? null : NotSent, now, now, CancellationToken.None);
        if (owned)
        {
            await outbox.CompleteCancelAsync(entry.InvoiceNumber, now, CancellationToken.None);
            await invoices.WriteSendOutcomeAsync(entry.InvoiceNumber, InvoiceStatus.Cancelled, null, null, now, CancellationToken.None);
            await transaction.CommitAsync(CancellationToken.None);
        }

        return owned;
    }
}
