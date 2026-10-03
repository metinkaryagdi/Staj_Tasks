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

    /// <summary>The ERP could not be asked (no answer, or an answer that is neither a readable 200 nor a 404).</summary>
    Unknown
}

/// <summary>Outcome of asking the ERP whether it already has an invoice.</summary>
public sealed record ErpLookupResult(ErpLookup Lookup, string? ErpReference, int? HttpStatus, string? Error, TimeSpan Elapsed);

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
}
