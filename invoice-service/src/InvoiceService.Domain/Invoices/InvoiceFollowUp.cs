namespace InvoiceService.Domain.Invoices;

/// <summary>
/// An operator looking after a stuck invoice (invoice_follow_ups): who, since when, and a note. At most one is open per
/// invoice; closed ones stay as the invoice's history. It does not change the invoice.
/// </summary>
public sealed class InvoiceFollowUp
{
    /// <summary>A note is a sentence or two.</summary>
    public const int MaxNoteLength = 500;

    public long Id { get; set; }
    public required string InvoiceNumber { get; set; }

    /// <summary>The name from X-Operator-Name, at most <see cref="Operators.OperatorAction.MaxNameLength"/>.</summary>
    public required string OperatorName { get; set; }

    public required string Note { get; set; }
    public DateTimeOffset OpenedAt { get; set; }

    /// <summary>Null while the follow-up is open.</summary>
    public DateTimeOffset? ClosedAt { get; set; }

    public string? ClosedBy { get; set; }
}
