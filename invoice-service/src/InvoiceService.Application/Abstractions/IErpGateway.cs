using System.Net.Http.Headers;
using InvoiceService.Domain.Invoices;

namespace InvoiceService.Application.Abstractions;

/// <summary>
/// Outcome of one request to the ERP. <see cref="HttpStatus"/> is null when no answer came (timeout, ERP unreachable).
/// <see cref="RetryAfter"/> is the Retry-After header as sent (seconds or an HTTP date), if there was one.
/// </summary>
public sealed record ErpSendResult(
    bool Accepted, string? ErpReference, int? HttpStatus, string? Error, TimeSpan Elapsed,
    RetryConditionHeaderValue? RetryAfter = null);

public enum ErpLookup
{
    /// <summary>The ERP has the invoice (GET 200 with an ERP reference).</summary>
    Found,

    /// <summary>The ERP does not have the invoice (GET 404).</summary>
    NotFound,

    /// <summary>The ERP could not be asked (no answer, or an answer that is neither a readable 200 nor a
    /// 404).</summary>
    Unknown
}

public static class ErpDecisionKind
{
    public const string None = "none";
    public const string Received = "received";
    public const string Approved = "approved";
    public const string Rejected = "rejected";
}

/// <param name="Kind">One of <see cref="ErpDecisionKind"/>.</param>
/// <param name="Reason">The rejection reason; only when rejected.</param>
public sealed record ErpDecision(string Kind, string? Reason = null, DateTimeOffset? DecidedAt = null)
{
    public static readonly ErpDecision None = new(ErpDecisionKind.None);
}

/// <summary>
/// Outcome of asking the ERP whether it already has an invoice. <see cref="Decision"/> is the ERP's decision about it
/// (<see cref="ErpDecision.None"/> when the ERP has not decided or did not say); only set when <see cref="Lookup"/>
/// is Found. <see cref="Records"/> are the ERP's records of the number (more than one if it has duplicates); null when
/// the answer did not carry them in a readable form.
/// </summary>
public sealed record ErpLookupResult(
    ErpLookup Lookup, string? ErpReference, int? HttpStatus, string? Error, TimeSpan Elapsed, ErpDecision? Decision = null,
    IReadOnlyList<ErpRecord>? Records = null);

/// <summary>One record the ERP has; an invoice number with duplicates has one per record.</summary>
public sealed record ErpRecord(
    string InvoiceNumber, string ErpReference, string CustomerCode, decimal Amount, string Currency, DateOnly InvoiceDate,
    DateTimeOffset ReceivedAt);

/// <param name="Records">Every record in the range, oldest first; empty unless <see cref="Succeeded"/>.</param>
/// <param name="Error">Why the list could not be read completely; null when it succeeded.</param>
public sealed record ErpListResult(bool Succeeded, IReadOnlyList<ErpRecord> Records, string? Error);

/// <summary>
/// The way out to the ERP. One call is exactly one request: deciding whether and when to try again is not done by the
/// implementation but by the outbox (RetryPolicy).
/// </summary>
public interface IErpGateway
{
    /// <summary>Sends the invoice with a single request. Only a 202 with an ERP reference counts as accepted.</summary>
    Task<ErpSendResult> SendAsync(Invoice invoice, CancellationToken ct);

    /// <summary>
    /// Asks the ERP whether it already has the invoice, without sending it. Only a 404 means "not there"; anything that
    /// is not a clear yes or no is <see cref="ErpLookup.Unknown"/>.
    /// </summary>
    Task<ErpLookupResult> FindAsync(string invoiceNumber, CancellationToken ct);

    /// <summary>
    /// Every record the ERP received in [<paramref name="from"/>, <paramref name="to"/>), all pages. A page that
    /// cannot be read fails the whole call: a partial list would look like records the ERP does not have.
    /// </summary>
    Task<ErpListResult> ListAsync(DateTimeOffset from, DateTimeOffset to, CancellationToken ct);
}
