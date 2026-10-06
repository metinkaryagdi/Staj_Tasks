using InvoiceService.Domain.Invoices;

namespace InvoiceService.Application.Invoices;

public sealed record ResendInvoicesRequest(IReadOnlyList<string>? InvoiceNumbers);

public enum BulkResendOutcome
{
    /// <summary>The invoice was Başarısız and is Bekliyor again.</summary>
    Queued,

    /// <summary>There is no such invoice.</summary>
    NotFound,

    /// <summary>The invoice exists but is not Başarısız (for example somebody else just queued it again).</summary>
    NotFailed,

    /// <summary>The resend itself failed (for example the database was unreachable); nothing was changed.</summary>
    Error
}

/// <param name="CurrentStatus">The invoice's status; set only for <see cref="BulkResendOutcome.NotFailed"/>.</param>
public sealed record BulkResendItem(string InvoiceNumber, BulkResendOutcome Outcome, string? CurrentStatus = null);

/// <param name="Errors">Set when the request itself is wrong; then nothing was resent.</param>
public sealed record BulkResendResult(IReadOnlyDictionary<string, string[]>? Errors, IReadOnlyList<BulkResendItem> Items);

/// <summary>
/// Queues several Başarısız invoices again. Each invoice goes through <see cref="ResendInvoiceHandler"/> on its own, so
/// the rules and the guard against two resends at the same time are the single resend's; one invoice that cannot be
/// queued does not stop the others.
/// </summary>
public sealed class ResendInvoicesHandler(ResendInvoiceHandler single, ILoggerFactory loggerFactory)
{
    /// <summary>A chosen limit: the screen allows at most this many selections, so one request stays short.</summary>
    public const int MaxInvoices = 100;

    private readonly ILogger _logger = loggerFactory.CreateLogger(InvoiceLog.Category);

    public async Task<BulkResendResult> HandleAsync(ResendInvoicesRequest request)
    {
        var numbers = request.InvoiceNumbers;
        if (numbers is null || numbers.Count == 0)
            return Invalid("At least one invoice number is required.");
        if (numbers.Count > MaxInvoices)
            return Invalid($"At most {MaxInvoices} invoice numbers can be resent at once (got {numbers.Count}).");
        if (numbers.Any(string.IsNullOrWhiteSpace))
            return Invalid("Invoice numbers must not be empty.");

        // The same number twice is resent once: the second would only be refused as "already queued".
        var distinct = numbers.Select(n => n.Trim()).Distinct().ToList();
        var items = new List<BulkResendItem>(distinct.Count);
        foreach (var number in distinct)
            items.Add(await ResendAsync(number));

        _logger.LogInformation(
            "Bulk resend requested={Requested} queued={Queued} refused={Refused} errors={Errors}",
            distinct.Count, items.Count(i => i.Outcome == BulkResendOutcome.Queued),
            items.Count(i => i.Outcome is BulkResendOutcome.NotFound or BulkResendOutcome.NotFailed),
            items.Count(i => i.Outcome == BulkResendOutcome.Error));
        return new BulkResendResult(null, items);
    }

    private async Task<BulkResendItem> ResendAsync(string number)
    {
        try
        {
            var result = await single.HandleAsync(number);
            return result.Status switch
            {
                ResendStatus.Queued => new BulkResendItem(number, BulkResendOutcome.Queued),
                ResendStatus.NotFound => new BulkResendItem(number, BulkResendOutcome.NotFound),
                _ => new BulkResendItem(number, BulkResendOutcome.NotFailed, result.CurrentStatus)
            };
        }
        catch (Exception ex)
        {
            _logger.LogError(ex, "Bulk resend failed for invoice={InvoiceNumber}", number);
            return new BulkResendItem(number, BulkResendOutcome.Error);
        }
    }

    private static BulkResendResult Invalid(string message) =>
        new(new Dictionary<string, string[]> { ["invoiceNumbers"] = [message] }, []);
}
