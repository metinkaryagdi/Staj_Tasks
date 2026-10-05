using InvoiceService.Application.Abstractions;
using InvoiceService.Application.Webhooks;
using InvoiceService.Domain.Invoices;

namespace InvoiceService.Application.Reconciliation;

/// <summary>
/// Writes one <see cref="Fix"/>. An invoice is changed in one transaction while its row lock is held, the lock an
/// incoming event and a resend take too, so they cannot interleave with this. The invoice is read again after the lock
/// is taken: if it is no longer what the plan saw, an event or a resend got there first and it is left alone.
/// </summary>
public sealed class FixApplier(
    IUnitOfWork unitOfWork, IInvoiceStore invoices, IOutboxStore outbox, IWebhookEventStore events,
    WebhookEventProcessor webhooks, TimeProvider time)
{
    private const string NoReason = "ERP sebep bildirmedi";

    /// <summary>True when the fix was written; false when it was left alone because things changed after the plan.</summary>
    public Task<bool> ApplyAsync(Fix fix) => fix.Kind switch
    {
        FixKind.ApplyDecision => ApplyDecisionAsync(fix),
        FixKind.RecoverFailed => RecoverFailedAsync(fix),
        FixKind.IgnoreEvent => events.IgnoreUnknownInvoiceAsync(fix.EventId!, CancellationToken.None),
        _ => throw new ArgumentOutOfRangeException(nameof(fix), fix.Kind, "Unknown fix.")
    };

    private async Task<bool> ApplyDecisionAsync(Fix fix)
    {
        await using var transaction = await unitOfWork.BeginAsync(CancellationToken.None);

        var invoice = await invoices.LockAsync(fix.InvoiceNumber, CancellationToken.None);
        if (invoice is null || invoice.Status != fix.ExpectedStatus || invoice.ErpReference != fix.ErpReference)
            return false;

        if (!TryApplyDecision(invoice, fix.Decision!))
            return false;

        await unitOfWork.SaveChangesAsync(CancellationToken.None);
        await transaction.CommitAsync(CancellationToken.None);
        return true;
    }

    private async Task<bool> RecoverFailedAsync(Fix fix)
    {
        await using var transaction = await unitOfWork.BeginAsync(CancellationToken.None);

        // A resend moves the invoice to Bekliyor under this same lock: whichever comes second sees the other's result.
        var invoice = await invoices.LockAsync(fix.InvoiceNumber, CancellationToken.None);
        if (invoice is null || invoice.Status != InvoiceStatus.Failed)
            return false;

        var now = time.GetUtcNow();
        invoice.Status = InvoiceStatus.Sent;
        invoice.ErpReference = fix.ErpReference;
        invoice.LastError = null;
        invoice.UpdatedAt = now;
        await unitOfWork.SaveChangesAsync(CancellationToken.None);

        // The outbox entry agrees with the invoice again; events that arrived while it was Başarısız are applied now.
        await outbox.CompleteFailedAsync(fix.InvoiceNumber, now, CancellationToken.None);
        await webhooks.ApplyWaitingAsync(fix.InvoiceNumber, now, CancellationToken.None);

        if (TryApplyDecision(invoice, fix.Decision!))
            await unitOfWork.SaveChangesAsync(CancellationToken.None);

        await transaction.CommitAsync(CancellationToken.None);
        return true;
    }

    /// <summary>Moves the invoice the way the ERP's decision would as an event; false if that changes nothing.</summary>
    private bool TryApplyDecision(Invoice invoice, ErpDecision decision)
    {
        var target = ReconciliationPlanner.DecisionTarget(invoice.Status, decision);
        if (target is null)
            return false;

        invoice.Status = target;
        if (target == InvoiceStatus.Rejected)
            invoice.RejectReason = decision.Reason ?? NoReason;
        invoice.UpdatedAt = time.GetUtcNow();
        return true;
    }
}
