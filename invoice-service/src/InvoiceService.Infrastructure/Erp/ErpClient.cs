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

    /// <summary>The most records the ERP returns per page.</summary>
    private const int ListPageSize = 500;

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
            // HttpClient.Timeout surfaces as TaskCanceledException (inner TimeoutException), not as
            // HttpRequestException.
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

    /// <summary>Asks the ERP whether it has the invoice. Only a 404 means "not there"; anything unclear is
    /// Unknown.</summary>
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
                return new ErpLookupResult(ErpLookup.Found, reference, status, null, watch.Elapsed, ReadDecision(body),
                    ReadRecords(body, invoiceNumber));

            return new ErpLookupResult(ErpLookup.Unknown, null, status,
                $"ERP'ye faturanın kaydı sorulamadı: GET {status} {response.ReasonPhrase} döndü: {Describe(body)}", watch.Elapsed);
        }
    }

    public async Task<ErpListResult> ListAsync(DateTimeOffset from, DateTimeOffset to, CancellationToken ct)
    {
        var records = new List<ErpRecord>();
        for (var page = 1; ; page++)
        {
            var url = $"api/v1/invoices?from={Uri.EscapeDataString(from.ToString("O"))}&to={Uri.EscapeDataString(to.ToString("O"))}" +
                      $"&page={page}&pageSize={ListPageSize}";
            try
            {
                using var response = await http.GetAsync(url, ct);
                if (response.StatusCode != HttpStatusCode.OK)
                    return ListFailed($"GET {(int)response.StatusCode} {response.ReasonPhrase} döndü (sayfa {page}).");

                var body = await response.Content.ReadFromJsonAsync<ErpListPage>(JsonSerializerOptions.Web, ct);
                if (body?.Items is null)
                    return ListFailed($"Sayfa {page} okunamadı: cevap beklenen biçimde değil.");

                records.AddRange(body.Items.Select(i => new ErpRecord(
                    i.InvoiceNumber, i.ErpReference, i.CustomerCode, i.Amount, i.Currency, i.InvoiceDate, i.ReceivedAt)));
                if (records.Count >= body.TotalCount)
                    return new ErpListResult(true, records, null);

                // An empty page before the count is reached: a partial list would read as records the ERP does not
                // have.
                if (body.Items.Count == 0)
                    return ListFailed($"Sayfa {page} boş geldi ama {body.TotalCount} kayıt bekleniyordu ({records.Count} okundu).");
            }
            catch (TaskCanceledException) when (!ct.IsCancellationRequested)
            {
                return ListFailed($"{http.Timeout.TotalSeconds:0} saniye içinde cevap vermedi (zaman aşımı, sayfa {page}).");
            }
            catch (HttpRequestException ex)
            {
                return ListFailed($"ERP'ye ulaşılamadı (sayfa {page}): {ex.Message}");
            }
            catch (JsonException)
            {
                return ListFailed($"Sayfa {page} okunamadı: cevap JSON değil.");
            }
        }
    }

    private static ErpListResult ListFailed(string error) => new(false, [], $"ERP kayıtları listelenemedi: {error}");

    /// <summary>The records of a lookup answer; null when the answer has no readable records.</summary>
    private static IReadOnlyList<ErpRecord>? ReadRecords(string body, string invoiceNumber)
    {
        try
        {
            var answer = JsonSerializer.Deserialize<ErpLookupBody>(body, JsonSerializerOptions.Web);
            return answer?.Records?.Select(r => new ErpRecord(
                invoiceNumber, r.ErpReference, r.CustomerCode, r.Amount, r.Currency, r.InvoiceDate, r.ReceivedAt)).ToList();
        }
        catch (JsonException)
        {
            return null;
        }
    }

    /// <summary>The decision fields of a lookup answer; none when they are missing.</summary>
    private static ErpDecision ReadDecision(string body)
    {
        try
        {
            using var json = JsonDocument.Parse(body);
            var root = json.RootElement;
            if (root.ValueKind != JsonValueKind.Object
                || !root.TryGetProperty("decision", out var kind) || kind.ValueKind != JsonValueKind.String)
                return ErpDecision.None;

            var reason = root.TryGetProperty("reason", out var r) && r.ValueKind == JsonValueKind.String ? r.GetString() : null;
            DateTimeOffset? decidedAt = root.TryGetProperty("decided_at", out var d) && d.ValueKind == JsonValueKind.String
                                        && d.TryGetDateTimeOffset(out var at) ? at : null;
            return new ErpDecision(kind.GetString()!, reason, decidedAt);
        }
        catch (JsonException)
        {
            return ErpDecision.None;
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
            // Only a string title is used: GetString throws on a number or an object, which would leave the entry
            // locked.
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

    private sealed record ErpLookupBody(List<ErpLookupRecord>? Records);

    private sealed record ErpLookupRecord(
        string ErpReference, string CustomerCode, decimal Amount, string Currency, DateOnly InvoiceDate, DateTimeOffset ReceivedAt);

    private sealed record ErpListPage(int TotalCount, List<ErpListItem>? Items);

    private sealed record ErpListItem(
        string InvoiceNumber, string ErpReference, string CustomerCode, decimal Amount, string Currency, DateOnly InvoiceDate,
        DateTimeOffset ReceivedAt);

    private sealed record ErpInvoiceRequest(
        string InvoiceNumber, string CustomerCode, decimal Amount, string Currency, DateOnly InvoiceDate);
}
