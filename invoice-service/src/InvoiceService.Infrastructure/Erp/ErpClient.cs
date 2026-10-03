using System.Diagnostics;
using System.Net;
using System.Net.Http.Json;
using System.Text.Json;
using InvoiceService.Application.Abstractions;
using InvoiceService.Domain.Invoices;

namespace InvoiceService.Infrastructure.Erp;

/// <summary>
/// Talks to the ERP over HTTP, one request per call. Only a 202 with an ERP reference counts as accepted; retrying is
/// up to the outbox.
/// </summary>
public sealed class ErpClient(HttpClient http) : IErpGateway
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
            {
                return new ErpSendResult(false, null, status, $"ERP {status} {response.ReasonPhrase} döndü: {Describe(body)}",
                    watch.Elapsed, response.Headers.RetryAfter);
            }

            var reference = ReadErpReference(body);
            if (reference is null)
                return Failed(status, $"ERP 202 döndü ama cevapta erpReference yok: {Describe(body)}", watch);

            return new ErpSendResult(true, reference, status, null, watch.Elapsed);
        }
    }

    /// <summary>Asks the ERP whether it has the invoice. Only a 404 means "not there"; anything unclear is Unknown.</summary>
    public async Task<ErpLookupResult> FindAsync(string invoiceNumber, CancellationToken ct)
    {
        var watch = Stopwatch.StartNew();

        HttpResponseMessage response;
        try
        {
            response = await http.GetAsync($"api/v1/invoices/{Uri.EscapeDataString(invoiceNumber)}", ct);
        }
        catch (TaskCanceledException) when (!ct.IsCancellationRequested)
        {
            return new ErpLookupResult(ErpLookup.Unknown, null, null,
                $"ERP'ye faturanın kaydı sorulamadı: {http.Timeout.TotalSeconds:0} saniye içinde cevap vermedi (zaman aşımı).", watch.Elapsed);
        }
        catch (HttpRequestException ex)
        {
            return new ErpLookupResult(ErpLookup.Unknown, null, null, $"ERP'ye faturanın kaydı sorulamadı: ERP'ye ulaşılamadı: {ex.Message}", watch.Elapsed);
        }

        using (response)
        {
            var body = await response.Content.ReadAsStringAsync(ct);
            var status = (int)response.StatusCode;

            if (response.StatusCode == HttpStatusCode.NotFound)
                return new ErpLookupResult(ErpLookup.NotFound, null, status, null, watch.Elapsed);

            if (response.StatusCode == HttpStatusCode.OK && ReadErpReference(body) is { } reference)
                return new ErpLookupResult(ErpLookup.Found, reference, status, null, watch.Elapsed);

            return new ErpLookupResult(ErpLookup.Unknown, null, status,
                $"ERP'ye faturanın kaydı sorulamadı: GET {status} {response.ReasonPhrase} döndü: {Describe(body)}", watch.Elapsed);
        }
    }

    private static ErpSendResult Failed(int? status, string error, Stopwatch watch) =>
        new(false, null, status, error, watch.Elapsed);

    private static string? ReadErpReference(string body)
    {
        try
        {
            using var json = JsonDocument.Parse(body);
            // TryGetProperty throws on anything but an object ([], null, 42, "x"); such a body has no reference.
            return json.RootElement.ValueKind == JsonValueKind.Object
                   && json.RootElement.TryGetProperty("erpReference", out var value) && value.ValueKind == JsonValueKind.String
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
            // Only a string title is used: GetString throws on a number or an object, which would leave the entry locked.
            if (root.ValueKind == JsonValueKind.Object && root.TryGetProperty("title", out var title) && title.ValueKind == JsonValueKind.String)
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
