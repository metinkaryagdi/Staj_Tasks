using InvoiceService.Application.Abstractions;
using InvoiceService.Application.Reconciliation;
using InvoiceService.Domain.Invoices;
using InvoiceService.Domain.Operators;

namespace InvoiceService.Application.Invoices;

public enum FollowUpStatus { Opened, Closed, InvoiceNotFound, NotStuck, AlreadyOpen, NotOpen, InvalidNote }

/// <param name="CurrentStatus">The invoice's status; set only for <see cref="FollowUpStatus.NotStuck"/>.</param>
/// <param name="ExistingOperator">Who opened the follow-up that is already open; only for
/// <see cref="FollowUpStatus.AlreadyOpen"/>.</param>
public sealed record FollowUpResult(
    FollowUpStatus Status, InvoiceFollowUp? FollowUp = null, string? CurrentStatus = null,
    string? ExistingOperator = null, DateTimeOffset? ExistingOpenedAt = null);

/// <summary>
/// An operator marks a stuck invoice as being looked after, and closes that again. The invoice itself does not change:
/// it stays stuck and the reconciliation still fixes it when the ERP decides. Every request, refused ones too, is
/// recorded in operator_actions in the same transaction.
/// </summary>
public sealed class InvoiceFollowUpHandler(
    IUnitOfWork unitOfWork, IInvoiceStore invoices, IInvoiceFollowUpStore followUps,
    IOperatorActionStore actions, TimeProvider time, IOptions<ReconciliationOptions> options)
{
    public async Task<FollowUpResult> OpenAsync(string invoiceNumber, string operatorName, string? note, CancellationToken ct)
    {
        var now = time.GetUtcNow();
        await using var transaction = await unitOfWork.BeginAsync(ct);
        // The invoice's row lock puts two requests for the same invoice one after the other: the second sees the first's
        // follow-up and is refused. The partial unique index is only the last guard.
        var invoice = await invoices.LockAsync(invoiceNumber, ct);
        FollowUpResult result;
        if (note is null || string.IsNullOrWhiteSpace(note) || note.Length > InvoiceFollowUp.MaxNoteLength)
            result = new(FollowUpStatus.InvalidNote);
        else if (invoice is null)
            result = new(FollowUpStatus.InvoiceNotFound);
        else if (!StuckInvoice.Before(now - options.Value.StuckAfter).Compile()(invoice))
            result = new(FollowUpStatus.NotStuck, CurrentStatus: invoice.Status);
        else if (await followUps.FindOpenAsync(invoiceNumber, ct) is { } existing)
            result = new(FollowUpStatus.AlreadyOpen, ExistingOperator: existing.OperatorName, ExistingOpenedAt: existing.OpenedAt);
        else
        {
            var followUp = new InvoiceFollowUp
            {
                InvoiceNumber = invoiceNumber, OperatorName = operatorName, Note = note.Trim(), OpenedAt = now
            };
            await followUps.AddAsync(followUp, ct);
            result = new(FollowUpStatus.Opened, followUp);
        }

        var actionResult = result.Status switch
        {
            FollowUpStatus.Opened => OperatorActionResult.FollowUpOpened,
            FollowUpStatus.InvoiceNotFound => OperatorActionResult.NotFound,
            FollowUpStatus.NotStuck => OperatorActionResult.NotStuck(result.CurrentStatus!),
            FollowUpStatus.AlreadyOpen => OperatorActionResult.AlreadyFollowed(result.ExistingOperator!),
            _ => OperatorActionResult.InvalidNote
        };
        await actions.RecordAsync(ResendInvoiceHandler.Record(operatorName, OperatorActionType.FollowUp, invoiceNumber, actionResult, now), ct);
        await transaction.CommitAsync(ct);
        return result;
    }

    public async Task<FollowUpResult> CloseAsync(string invoiceNumber, string operatorName, CancellationToken ct)
    {
        var now = time.GetUtcNow();
        await using var transaction = await unitOfWork.BeginAsync(ct);
        await invoices.LockAsync(invoiceNumber, ct);
        var existing = await followUps.FindOpenAsync(invoiceNumber, ct);
        var result = existing is null
            ? new FollowUpResult(FollowUpStatus.NotOpen)
            : new FollowUpResult(FollowUpStatus.Closed, existing);
        if (existing is not null)
        {
            await followUps.CloseAsync(existing.Id, operatorName, now, ct);
            existing.ClosedAt = now;
            existing.ClosedBy = operatorName;
        }
        var actionResult = existing is null ? OperatorActionResult.FollowUpNotOpen : OperatorActionResult.FollowUpClosed;
        await actions.RecordAsync(ResendInvoiceHandler.Record(operatorName, OperatorActionType.CloseFollowUp, invoiceNumber, actionResult, now), ct);
        await transaction.CommitAsync(ct);
        return result;
    }
}
