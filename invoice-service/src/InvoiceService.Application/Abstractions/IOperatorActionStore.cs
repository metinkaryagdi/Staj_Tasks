using InvoiceService.Domain.Operators;

namespace InvoiceService.Application.Abstractions;

/// <summary>Storage of the interventions made from the operations screen (operator_actions).</summary>
public interface IOperatorActionStore
{
    /// <summary>
    /// Writes the record at once, in the open transaction if there is one (rolled back with it). Nothing is left
    /// behind in the unit of work: a record that fails to be written is not written later by someone else's save.
    /// </summary>
    Task RecordAsync(OperatorAction action, CancellationToken ct);

    /// <summary>The records about this invoice, newest first.</summary>
    Task<IReadOnlyList<OperatorAction>> ListOfInvoiceAsync(string invoiceNumber, CancellationToken ct);
}
