namespace ErpSimulator.Api.Invoices;

public sealed record InvoiceAcceptedResponse(string ErpReference, string InvoiceNumber, DateTimeOffset ReceivedAt);

public sealed record InvoiceRecordResponse(
    string ErpReference,
    string CustomerCode,
    decimal Amount,
    string Currency,
    DateOnly InvoiceDate,
    DateTimeOffset ReceivedAt);

/// <summary>
/// One invoice number can map to several ERP records (duplicates are allowed): <see cref="ErpReference"/> is the first, and
/// the decision (none, received, approved, rejected) is the first record's, shown once its time has come even if its event
/// was never sent. <see cref="Reason"/> only when rejected; <see cref="DecidedAt"/> when approved or rejected.
/// </summary>
public sealed record InvoiceLookupResponse(
    string InvoiceNumber,
    bool Registered,
    string ErpReference,
    int RecordCount,
    IReadOnlyList<InvoiceRecordResponse> Records,
    string Decision,
    string? Reason,
    DateTimeOffset? DecidedAt);

/// <summary>One ERP record in the list; a duplicated invoice number is listed once per record.</summary>
public sealed record InvoiceListItemResponse(
    string InvoiceNumber,
    string ErpReference,
    string CustomerCode,
    decimal Amount,
    string Currency,
    DateOnly InvoiceDate,
    DateTimeOffset ReceivedAt);

/// <param name="TotalCount">All records in the range, not only this page.</param>
public sealed record InvoiceListResponse(int Page, int PageSize, int TotalCount, IReadOnlyList<InvoiceListItemResponse> Items);
