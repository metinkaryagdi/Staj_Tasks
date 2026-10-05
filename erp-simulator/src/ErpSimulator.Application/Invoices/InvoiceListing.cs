using ErpSimulator.Application.Abstractions;

namespace ErpSimulator.Application.Invoices;

/// <param name="From">Inclusive.</param>
/// <param name="To">Exclusive.</param>
/// <param name="Page">Starting at 1.</param>
public sealed record InvoiceListRequest(DateTimeOffset? From, DateTimeOffset? To, int Page, int PageSize)
{
    public const int MaxPageSize = 500;

    public Dictionary<string, string[]> Validate()
    {
        var errors = new Dictionary<string, string[]>();

        if (From is null)
            errors[nameof(From)] = ["Required, ISO 8601 date and time."];

        if (To is null)
            errors[nameof(To)] = ["Required, ISO 8601 date and time."];

        if (From is not null && To is not null && From >= To)
            errors[nameof(To)] = ["Must be later than from."];

        if (Page < 1)
            errors[nameof(Page)] = ["Must be at least 1."];

        if (PageSize is < 1 or > MaxPageSize)
            errors[nameof(PageSize)] = [$"Must be between 1 and {MaxPageSize}."];

        return errors;
    }
}

/// <param name="Errors">Set when the request is invalid (400); then <paramref name="Page"/> is null.</param>
public sealed record InvoiceListResult(Dictionary<string, string[]>? Errors, InvoicePage? Page);

/// <summary>Lists the ERP's records received in a time range, one page at a time. No faults are injected here.</summary>
public sealed class InvoiceListing(IErpInvoiceStore invoices)
{
    public async Task<InvoiceListResult> ListAsync(InvoiceListRequest request, CancellationToken ct)
    {
        var errors = request.Validate();
        if (errors.Count > 0)
            return new InvoiceListResult(errors, null);

        // Worked out in long: a very large page times the page size must not wrap into a negative offset. Past int.MaxValue
        // it is far beyond the last record anyway, so it is cut there and the page comes back empty.
        var skip = (int)Math.Min((long)(request.Page - 1) * request.PageSize, int.MaxValue);
        var page = await invoices.ListReceivedAsync(request.From!.Value, request.To!.Value, skip, request.PageSize, ct);
        return new InvoiceListResult(null, page);
    }
}
