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
/// Because the simulator allows duplicates, one invoice number can map to several ERP records.
/// <see cref="ErpReference"/> is the first (oldest) one; <see cref="Records"/> lists all of them. The decision is the
/// first record's: none, received, approved or rejected (<see cref="Reason"/> only when rejected, <see cref="DecidedAt"/>
/// when approved or rejected), whether or not its event was ever sent.
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
