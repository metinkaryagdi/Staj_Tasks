using System.Diagnostics;
using System.Net;
using System.Net.Http.Json;
using System.Text.Json;
using InvoiceService.Data;

namespace InvoiceService.Erp;

public sealed record ErpSendResult(bool Accepted, string? ErpReference, int? HttpStatus, string? Error, TimeSpan Elapsed);

/// <summary>
/// Sends one invoice to the ERP simulator exactly once. Deliberately unprotected in this version:
/// no retry, no waiting, no duplicate protection and the Retry-After header is not read.
/// Only a 202 with an ERP reference counts as accepted; every other outcome is returned as a failure.
/// </summary>
public sealed class ErpClient(HttpClient http)
{
    private const int MaxBodyInError = 500;

    public async Task<ErpSendResult> SendAsync(Invoice invoice, CancellationToken ct)
    {
        var request = new ErpInvoiceRequest(
            invoice.InvoiceNumber, invoice.CustomerCode, invoice.Amount, invoice.Currency, invoice.InvoiceDate);
        var watch = Stopwatch.StartNew();

        HttpResponseMessage response;
        try
        {
            // Default completion option buffers the whole body, so HttpClient.Timeout covers headers and body.
            response = await http.PostAsJsonAsync("api/v1/invoices", request, ct);
        }
        catch (TaskCanceledException) when (!ct.IsCancellationRequested)
        {
            // HttpClient.Timeout surfaces as TaskCanceledException (inner TimeoutException), not as HttpRequestException.
            return Failed(null, $"ERP {http.Timeout.TotalSeconds:0} saniye içinde cevap vermedi (zaman aşımı).", watch);
        }
        catch (HttpRequestException ex)
        {
            return Failed(null, $"ERP'ye ulaşılamadı: {ex.Message}", watch);
        }

        using (response)
        {
            var body = await response.Content.ReadAsStringAsync(ct);
            var status = (int)response.StatusCode;

            if (response.StatusCode != HttpStatusCode.Accepted)
                return Failed(status, $"ERP {status} {response.ReasonPhrase} döndü: {Describe(body)}", watch);

            var reference = ReadErpReference(body);
            if (reference is null)
                return Failed(status, $"ERP 202 döndü ama cevapta erpReference yok: {Describe(body)}", watch);

            return new ErpSendResult(true, reference, status, null, watch.Elapsed);
        }
    }

    private static ErpSendResult Failed(int? status, string error, Stopwatch watch) =>
        new(false, null, status, error, watch.Elapsed);

    private static string? ReadErpReference(string body)
    {
        try
        {
            using var json = JsonDocument.Parse(body);
            return json.RootElement.TryGetProperty("erpReference", out var value) && value.ValueKind == JsonValueKind.String
                   && !string.IsNullOrWhiteSpace(value.GetString())
                ? value.GetString()
                : null;
        }
        catch (JsonException)
        {
            return null;
        }
    }

    /// <summary>Title and detail of a problem+json body, otherwise the raw body (shortened).</summary>
    private static string Describe(string body)
    {
        if (string.IsNullOrWhiteSpace(body))
            return "(boş gövde)";

        try
        {
            using var json = JsonDocument.Parse(body);
            var root = json.RootElement;
            if (root.ValueKind == JsonValueKind.Object && root.TryGetProperty("title", out var title))
            {
                return root.TryGetProperty("detail", out var detail) && detail.ValueKind == JsonValueKind.String
                    ? $"{title.GetString()} - {detail.GetString()}"
                    : title.GetString() ?? body;
            }
        }
        catch (JsonException)
        {
            // Not JSON: fall through to the raw body.
        }

        return body.Length <= MaxBodyInError ? body : body[..MaxBodyInError] + "...";
    }

    private sealed record ErpInvoiceRequest(
        string InvoiceNumber, string CustomerCode, decimal Amount, string Currency, DateOnly InvoiceDate);
}
