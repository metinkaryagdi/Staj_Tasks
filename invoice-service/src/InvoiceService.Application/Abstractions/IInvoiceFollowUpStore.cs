using InvoiceService.Domain.Invoices;

namespace InvoiceService.Application.Abstractions;

/// <summary>Storage of the follow-ups operators open on stuck invoices (invoice_follow_ups).</summary>
public interface IInvoiceFollowUpStore
{
    /// <summary>The invoice's open follow-up, if there is one.</summary>
    Task<InvoiceFollowUp?> FindOpenAsync(string invoiceNumber, CancellationToken ct);

    /// <summary>Every follow-up of the invoice, open or closed, newest first.</summary>
    Task<IReadOnlyList<InvoiceFollowUp>> ListAsync(string invoiceNumber, CancellationToken ct);

    /// <summary>Writes a new open follow-up in the open transaction.</summary>
    Task AddAsync(InvoiceFollowUp followUp, CancellationToken ct);

    Task CloseAsync(long id, string closedBy, DateTimeOffset closedAt, CancellationToken ct);

    /// <summary>For each of these invoices that has an open follow-up, who opened it.</summary>
    Task<IReadOnlyDictionary<string, string>> OpenNamesAsync(IReadOnlyCollection<string> invoiceNumbers, CancellationToken ct);
}
