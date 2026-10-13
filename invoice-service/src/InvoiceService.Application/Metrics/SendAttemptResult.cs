using InvoiceService.Application.Abstractions;
using InvoiceService.Application.Outbox;

namespace InvoiceService.Application.Metrics;

/// <summary>The result label of erp.send.attempts.</summary>
public static class SendAttemptResult
{
    public const string Accepted = "accepted";
    public const string Busy = "busy";
    public const string ServerError = "server_error";
    public const string Timeout = "timeout";
    public const string Unreachable = "unreachable";
    public const string AlreadyExists = "already_exists";

    public static readonly string[] All = [Accepted, Busy, ServerError, Timeout, Unreachable, AlreadyExists];

    /// <summary>
    /// What one attempt ended with. An attempt that only asked the ERP counts too: "already there" is learnt by asking,
    /// and a question that got no answer ends the attempt like a POST that got none. Null for an answer that is none of
    /// these (a 4xx other than 429, a 202 without an ERP reference): not counted.
    /// </summary>
    public static string? Of(SendAttempt attempt)
    {
        var result = attempt.Result;
        if (attempt.Path == SendPath.Found)
            return AlreadyExists;
        if (result.Accepted)
            return Accepted;

        return result.HttpStatus switch
        {
            429 => Busy,
            >= 500 => ServerError,
            null => result.NoAnswer switch
            {
                ErpNoAnswer.Timeout => Timeout,
                ErpNoAnswer.Unreachable => Unreachable,
                _ => null
            },
            _ => null
        };
    }
}
