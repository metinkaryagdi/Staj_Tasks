namespace ErpSimulator.Application.Abstractions;

/// <summary>What came back from one webhook POST: the HTTP status (null without an answer) and the error, if any.</summary>
public sealed record WebhookPostResult(int? HttpStatus, string? Error);

/// <summary>The way out to the invoice service.</summary>
public interface IWebhookTransport
{
    /// <summary>
    /// POSTs the signed body once. No 2xx within <paramref name="timeout"/> is reported as an error, not thrown.
    /// Throws <see cref="OperationCanceledException"/> only when <paramref name="stoppingToken"/> is cancelled.
    /// </summary>
    Task<WebhookPostResult> PostAsync(
        string url, byte[] body, string timestamp, string signature, TimeSpan timeout, CancellationToken stoppingToken);
}
