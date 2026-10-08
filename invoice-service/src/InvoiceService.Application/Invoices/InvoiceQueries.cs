using InvoiceService.Application.Abstractions;
using InvoiceService.Application.Reconciliation;
using InvoiceService.Domain.Invoices;
using InvoiceService.Domain.Reconciliation;

namespace InvoiceService.Application.Invoices;

/// <summary>Reads invoices as stored by the service.</summary>
public sealed class InvoiceQueries(
    IInvoiceStore invoices, IOutboxStore outbox, IWebhookEventStore events, IReconciliationStore reconciliation,
    IOperatorActionStore actions, IInvoiceFollowUpStore followUps, IOptions<ReconciliationOptions> reconciliationOptions, TimeProvider time)
{
    public const int DefaultPageSize = 20;

    /// <summary>A chosen limit: a page is one response, and the screen's bulk resend takes at most this many too.</summary>
    public const int MaxPageSize = 100;

    /// <summary>
    /// Newest first; <paramref name="search"/> is part of the invoice number. <paramref name="stuck"/>: only the invoices
    /// the summary counts as stuck.
    /// </summary>
    public async Task<InvoiceListPage> ListAsync(
        string? status, string? search, bool stuck, int page, int pageSize, CancellationToken ct)
    {
        // One moment for the filter and for the flags, so a listed invoice is never filtered as stuck and shown as not.
        var cutoff = StuckBefore();
        var result = await invoices.ListPageAsync(
            status, string.IsNullOrWhiteSpace(search) ? null : search.Trim(),
            stuck ? cutoff : null, (page - 1) * pageSize, pageSize, ct);
        var isStuck = StuckInvoice.Before(cutoff).Compile();
        var openNames = await followUps.OpenNamesAsync(result.Items.Select(i => i.InvoiceNumber).ToList(), ct);
        return new InvoiceListPage(result.Items.Select(i => new ListedInvoice(i, isStuck(i), openNames.GetValueOrDefault(i.InvoiceNumber))).ToList(), result.TotalCount);
    }

    /// <summary>Whether the summary counts the invoice as stuck right now.</summary>
    public bool IsStuck(Invoice invoice) => StuckInvoice.Before(StuckBefore()).Compile()(invoice);

    /// <summary>Null if there is no such invoice.</summary>
    public Task<Invoice?> FindAsync(string invoiceNumber, CancellationToken ct) => invoices.FindAsync(invoiceNumber, ct);

    /// <summary>The summary's "sent in the last minute".</summary>
    public static readonly TimeSpan SentWindow = TimeSpan.FromMinutes(1);

    public async Task<InvoiceSummary> SummaryAsync(CancellationToken ct)
    {
        var options = reconciliationOptions.Value;
        var byStatus = await invoices.CountByStatusAsync(ct);
        var stuck = await invoices.CountStuckAsync(StuckBefore(), ct);

        var now = time.GetUtcNow();
        var queue = await outbox.QueueStatsAsync(now - SentWindow, ct);
        var oldestSeconds = queue.OldestQueuedAt is { } oldest ? (long)Math.Max(0, (now - oldest).TotalSeconds) : (long?)null;

        var counts = InvoiceStatus.All.Select(s => new StatusCount(s, byStatus.GetValueOrDefault(s))).ToList();
        return new InvoiceSummary(
            counts, counts.Sum(c => c.Count), stuck, options.StuckAfterMinutes, queue.Queued, oldestSeconds, queue.CompletedSince);
    }

    /// <summary>
    /// "ERP Karar Vermedi" is written again by every run while the ERP stays silent; only the newest is shown. The list
    /// comes newest first, so that is the first one.
    /// </summary>
    private static List<ReconciliationFinding> WithoutRepeatedNoDecision(IReadOnlyList<ReconciliationFinding> findings)
    {
        var newest = findings.FirstOrDefault(f => f.FindingType == FindingType.NoErpDecision);
        return findings.Where(f => f.FindingType != FindingType.NoErpDecision || ReferenceEquals(f, newest)).ToList();
    }

    private DateTimeOffset StuckBefore() => time.GetUtcNow() - reconciliationOptions.Value.StuckAfter;

    /// <summary>Null if there is no such invoice.</summary>
    public async Task<InvoiceDetails?> DetailsAsync(string invoiceNumber, CancellationToken ct)
    {
        var invoice = await invoices.FindAsync(invoiceNumber, ct);
        if (invoice is null)
            return null;

        return new InvoiceDetails(
            invoice,
            await outbox.FindAsync(invoiceNumber, ct),
            await events.ListByInvoiceAsync(invoiceNumber, ct),
            WithoutRepeatedNoDecision(await reconciliation.ListFindingsOfInvoiceAsync(invoiceNumber, ct)),
            await actions.ListOfInvoiceAsync(invoiceNumber, ct),
            IsStuck(invoice),
            await followUps.FindOpenAsync(invoiceNumber, ct),
            await followUps.ListAsync(invoiceNumber, ct));
    }
}
