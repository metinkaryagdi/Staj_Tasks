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
/// <see cref="ErpReference"/> is the first (oldest) one; <see cref="Records"/> lists all of them.
/// </summary>
public sealed record InvoiceLookupResponse(
    string InvoiceNumber,
    bool Registered,
    string ErpReference,
    int RecordCount,
    IReadOnlyList<InvoiceRecordResponse> Records);
