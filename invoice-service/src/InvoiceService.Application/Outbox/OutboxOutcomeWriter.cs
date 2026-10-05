using InvoiceService.Application.Abstractions;
using InvoiceService.Application.Webhooks;
using InvoiceService.Domain.Invoices;
using InvoiceService.Domain.Outbox;

namespace InvoiceService.Application.Outbox;

/// <summary>
/// Writes the outcome of an attempt to erp_outbox and invoices in one transaction, and applies the ERP events that were
/// waiting for the invoice when it becomes Gönderildi.
/// </summary>
public sealed class OutboxOutcomeWriter(
    IUnitOfWork unitOfWork, IOutboxStore outbox, IInvoiceStore invoices, WebhookEventProcessor events)
{
    /// <summary>
    /// Returns false when the entry no longer carries this claim: nothing was written (see
    /// <see cref="IOutboxStore.WriteOutcomeAsync"/>).
    /// </summary>
    public async Task<bool> WriteAsync(ClaimedEntry entry, RetryDecision decision, ErpSendResult result, DateTimeOffset now)
    {
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

        if (owned)
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
}
