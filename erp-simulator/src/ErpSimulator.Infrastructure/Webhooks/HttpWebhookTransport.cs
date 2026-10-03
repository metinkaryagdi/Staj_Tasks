using System.Net.Http.Headers;
using ErpSimulator.Application.Abstractions;
using ErpSimulator.Application.Webhooks;

namespace ErpSimulator.Infrastructure.Webhooks;

/// <summary>
/// POSTs a signed event to the invoice service. The HttpClient itself has no timeout (Timeout.InfiniteTimeSpan); the
/// limit is applied per send with its own token, so the client never cuts a send short.
/// </summary>
public sealed class HttpWebhookTransport(HttpClient http) : IWebhookTransport
{
    public const string HttpClientName = "webhooks";

    public async Task<WebhookPostResult> PostAsync(
        string url, byte[] body, string timestamp, string signature, TimeSpan timeout, CancellationToken stoppingToken)
    {
        using var request = new HttpRequestMessage(HttpMethod.Post, url);
        request.Content = new ByteArrayContent(body);
        request.Content.Headers.ContentType = new MediaTypeHeaderValue("application/json");
        request.Headers.TryAddWithoutValidation(WebhookSignature.TimestampHeader, timestamp);
        request.Headers.TryAddWithoutValidation(WebhookSignature.SignatureHeader, signature);

        try
        {
            using var limit = CancellationTokenSource.CreateLinkedTokenSource(stoppingToken);
            limit.CancelAfter(timeout);
            using var response = await http.SendAsync(request, limit.Token);
            var httpStatus = (int)response.StatusCode;
            return new WebhookPostResult(httpStatus, response.IsSuccessStatusCode ? null : $"HTTP {httpStatus}");
        }
        catch (OperationCanceledException) when (stoppingToken.IsCancellationRequested)
        {
            throw; // Shutting down: the caller leaves the row as it is.
        }
        catch (OperationCanceledException)
        {
            return new WebhookPostResult(null, $"no answer within {timeout.TotalSeconds:0} s");
        }
        catch (HttpRequestException ex)
        {
            return new WebhookPostResult(null, ex.Message);
        }
    }
}
