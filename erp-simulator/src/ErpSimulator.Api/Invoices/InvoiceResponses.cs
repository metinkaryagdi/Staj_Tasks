using System.Text.Json.Serialization;

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
/// One invoice number can map to several ERP records (duplicates are allowed): <see cref="ErpReference"/> is the
/// first, and the decision (none, received, approved, rejected) is the first record's, shown once its time has come
/// even if its event was never sent; once the invoice is cancelled it is cancelled. <see cref="Reason"/> only when
/// rejected; <see cref="DecidedAt"/> when approved or rejected. <see cref="CancelReference"/> and <see cref="CancelledAt"/> once the invoice is cancelled.
/// </summary>
public sealed record InvoiceLookupResponse(
    string InvoiceNumber,
    bool Registered,
    string ErpReference,
    int RecordCount,
    IReadOnlyList<InvoiceRecordResponse> Records,
    string Decision,
    string? Reason,
    [property: JsonPropertyName("decided_at")] DateTimeOffset? DecidedAt,
    string? CancelReference,
    [property: JsonPropertyName("cancelled_at")] DateTimeOffset? CancelledAt);

public sealed record CancellationAcceptedResponse(string CancelReference, string InvoiceNumber, DateTimeOffset CancelledAt);

/// <summary>One ERP record in the list; a duplicated invoice number is listed once per record.</summary>
public sealed record InvoiceListItemResponse(
    string InvoiceNumber,
    string ErpReference,
    string CustomerCode,
    decimal Amount,
    string Currency,
    DateOnly InvoiceDate,
    DateTimeOffset ReceivedAt,
    string? CancelReference);

/// <param name="TotalCount">All records in the range, not only this page.</param>
public sealed record InvoiceListResponse(int Page, int PageSize, int TotalCount, IReadOnlyList<InvoiceListItemResponse> Items);

public sealed record InvoiceAcceptedResponseV2(
    string ErpReference, string InvoiceNumber, string CustomerCode, long AmountKurus, string Currency, DateOnly InvoiceDate,
    DateTimeOffset ReceivedAt);

public sealed record InvoiceRecordResponseV2(
    string ErpReference, string CustomerCode, long AmountKurus, string Currency, DateOnly InvoiceDate, DateTimeOffset ReceivedAt);

public sealed record InvoiceLookupResponseV2(
    string InvoiceNumber,
    bool Registered,
    string ErpReference,
    int RecordCount,
    IReadOnlyList<InvoiceRecordResponseV2> Records,
    string Decision,
    string? Reason,
    [property: JsonPropertyName("decided_at")] DateTimeOffset? DecidedAt,
    string? CancelReference,
    [property: JsonPropertyName("cancelled_at")] DateTimeOffset? CancelledAt);

public sealed record InvoiceListItemResponseV2(
    string InvoiceNumber, string ErpReference, string CustomerCode, long AmountKurus, string Currency, DateOnly InvoiceDate,
    DateTimeOffset ReceivedAt, string? CancelReference);

public sealed record InvoiceListResponseV2(int Page, int PageSize, int TotalCount, IReadOnlyList<InvoiceListItemResponseV2> Items);
