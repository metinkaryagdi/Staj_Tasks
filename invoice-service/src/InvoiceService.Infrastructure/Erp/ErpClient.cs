using System.Diagnostics;
using System.Net;
using System.Net.Http.Json;
using System.Text.Json;
using InvoiceService.Application.Abstractions;
using InvoiceService.Domain.Invoices;

namespace InvoiceService.Infrastructure.Erp;

/// <summary>
/// Talks to the ERP over HTTP, in the API version <see cref="IErpVersionSetting"/> gives for each request. Amounts are
/// kuruş only in v2, and only here. One request per call, except that a v1 request answered "closed" (410) is made again
/// with v2 in the same call: it is not the invoice's fault and uses up no attempt. Only a 202 with an ERP reference counts
/// as accepted, and in v2 only if the record it returns is this invoice; retrying is up to the outbox.
/// </summary>
public sealed class ErpClient(HttpClient http, IErpVersionSetting versions) : IErpGateway
{
    private const int MaxBodyInError = 500;

    /// <summary>The title of the ERP's own 404. Any other 404 (the version's address is not there yet) says nothing about the
    /// invoice.</summary>
    private const string InvoiceNotFoundTitle = "Invoice not found";

    /// <summary>The most records the ERP returns per page.</summary>
    private const int ListPageSize = 500;

    private static string Invoices(int version) => $"api/v{version}/invoices";

    private async Task<int> VersionForAsync(string invoiceNumber, CancellationToken ct) =>
        ErpVersion.For(invoiceNumber, await versions.GetV2PercentAsync(ct));

    /// <summary>The request in the given version; once more with v2 if v1 answers that it is closed.</summary>
    private static async Task<HttpResponseMessage> RequestAsync(int version, Func<int, Task<HttpResponseMessage>> request)
    {
        var response = await request(version);
        if (response.StatusCode != HttpStatusCode.Gone || version != ErpVersion.V1)
            return response;

        response.Dispose();
        return await request(ErpVersion.V2);
    }

    public async Task<ErpSendResult> SendAsync(Invoice invoice, CancellationToken ct)
    {
        var version = await VersionForAsync(invoice.InvoiceNumber, ct);
        return await PostAsync(version, v => v == ErpVersion.V2
            ? http.PostAsJsonAsync(Invoices(v), new ErpInvoiceRequestV2(
                invoice.InvoiceNumber, invoice.CustomerCode, (long)(invoice.Amount * 100m), invoice.Currency, invoice.InvoiceDate), ct)
            : http.PostAsJsonAsync(Invoices(v), new ErpInvoiceRequest(
                invoice.InvoiceNumber, invoice.CustomerCode, invoice.Amount, invoice.Currency, invoice.InvoiceDate), ct),
            "erpReference", ct, body => DifferentRecord(invoice, body));
    }

    /// <summary>
    /// v2 answers a number it already has with 202 and that record, whatever was sent: refused when the record is not this
    /// invoice. v1's 202 carries no record (it saves what was sent): null, nothing to compare.
    /// </summary>
    private static ErpSendResult? DifferentRecord(Invoice invoice, string body)
    {
        ErpAcceptedRecord? answer;
        try
        {
            answer = JsonSerializer.Deserialize<ErpAcceptedRecord>(body, JsonSerializerOptions.Web);
        }
        catch (JsonException)
        {
            return null;
        }

        if (answer?.CustomerCode is null || answer.Currency is null || answer.InvoiceDate is null
            || (answer.AmountKurus is null && answer.Amount is null))
            return null;

        var record = new ErpRecord(invoice.InvoiceNumber, answer.ErpReference ?? "", answer.CustomerCode,
            ReadAmount(answer.Amount, answer.AmountKurus), answer.Currency, answer.InvoiceDate.Value, answer.ReceivedAt ?? default);
        var differences = record.DifferencesFrom(invoice);
        return differences.Count == 0
            ? null
            : ErpSendResult.DifferentContent((int)HttpStatusCode.Accepted, answer.ErpReference, differences, TimeSpan.Zero);
    }

    public async Task<ErpSendResult> CancelAsync(string invoiceNumber, CancellationToken ct)
    {
        var version = await VersionForAsync(invoiceNumber, ct);
        return await PostAsync(version,
            v => http.PostAsync($"{Invoices(v)}/{Uri.EscapeDataString(invoiceNumber)}/cancel", null, ct), "cancelReference", ct);
    }

    /// <summary>One POST; accepted only on 202 with <paramref name="referenceField"/> in the body, and only if
    /// <paramref name="refuseAccepted"/> (when given) finds nothing wrong with that body.</summary>
    private async Task<ErpSendResult> PostAsync(
        int version, Func<int, Task<HttpResponseMessage>> post, string referenceField, CancellationToken ct,
        Func<string, ErpSendResult?>? refuseAccepted = null)
    {
        var watch = Stopwatch.StartNew();

        HttpResponseMessage response;
        try
        {
            // Default completion option buffers the whole body, so HttpClient.Timeout covers headers and body.
            response = await RequestAsync(version, post);
        }
        catch (TaskCanceledException) when (!ct.IsCancellationRequested)
        {
            // HttpClient.Timeout surfaces as TaskCanceledException (inner TimeoutException), not as
            // HttpRequestException.
            return Failed(null, $"ERP {http.Timeout.TotalSeconds:0} saniye içinde cevap vermedi (zaman aşımı).", watch, ErpNoAnswer.Timeout);
        }
        catch (HttpRequestException ex)
        {
            return Failed(null, $"ERP'ye ulaşılamadı: {ex.Message}", watch, ErpNoAnswer.Unreachable);
        }

        using (response)
        {
            var body = await response.Content.ReadAsStringAsync(ct);
            var status = (int)response.StatusCode;

            if (response.StatusCode == HttpStatusCode.NotFound && ReadString(body, "title") != InvoiceNotFoundTitle)
                return Failed(null, $"ERP'nin bu adresi yok (404): {Describe(body)}", watch, ErpNoAnswer.Unreachable);

            if (response.StatusCode != HttpStatusCode.Accepted)
            {
                return new ErpSendResult(false, null, status, $"ERP {status} {response.ReasonPhrase} döndü: {Describe(body)}",
                    watch.Elapsed, response.Headers.RetryAfter);
            }

            var reference = ReadString(body, referenceField);
            if (reference is null)
                return Failed(status, $"ERP 202 döndü ama cevapta {referenceField} yok: {Describe(body)}", watch);

            if (refuseAccepted?.Invoke(body) is { } refused)
                return refused with { Elapsed = watch.Elapsed };

            return new ErpSendResult(true, reference, status, null, watch.Elapsed);
        }
    }

    /// <summary>Asks the ERP whether it has the invoice. Only a 404 means "not there"; anything unclear is
    /// Unknown.</summary>
    public async Task<ErpLookupResult> FindAsync(string invoiceNumber, CancellationToken ct)
    {
        var watch = Stopwatch.StartNew();
        var version = await VersionForAsync(invoiceNumber, ct);

        HttpResponseMessage response;
        try
        {
            response = await RequestAsync(version, v => http.GetAsync($"{Invoices(v)}/{Uri.EscapeDataString(invoiceNumber)}", ct));
        }
        catch (TaskCanceledException) when (!ct.IsCancellationRequested)
        {
            return new ErpLookupResult(ErpLookup.Unknown, null, null,
                $"ERP'ye faturanın kaydı sorulamadı: {http.Timeout.TotalSeconds:0} saniye içinde cevap vermedi (zaman aşımı).", watch.Elapsed,
                NoAnswer: ErpNoAnswer.Timeout);
        }
        catch (HttpRequestException ex)
        {
            return new ErpLookupResult(ErpLookup.Unknown, null, null, $"ERP'ye faturanın kaydı sorulamadı: ERP'ye ulaşılamadı: {ex.Message}", watch.Elapsed,
                NoAnswer: ErpNoAnswer.Unreachable);
        }

        using (response)
        {
            var body = await response.Content.ReadAsStringAsync(ct);
            var status = (int)response.StatusCode;

            if (response.StatusCode == HttpStatusCode.NotFound && ReadString(body, "title") == InvoiceNotFoundTitle)
                return new ErpLookupResult(ErpLookup.NotFound, null, status, null, watch.Elapsed);

            if (response.StatusCode == HttpStatusCode.OK && ReadString(body, "erpReference") is { } reference)
                return new ErpLookupResult(ErpLookup.Found, reference, status, null, watch.Elapsed, ReadDecision(body),
                    ReadRecords(body, invoiceNumber), CancelReference: ReadString(body, "cancelReference"));

            return new ErpLookupResult(ErpLookup.Unknown, null, status,
                $"ERP'ye faturanın kaydı sorulamadı: GET {status} {response.ReasonPhrase} döndü: {Describe(body)}", watch.Elapsed);
        }
    }

    public async Task<ErpListResult> ListAsync(DateTimeOffset from, DateTimeOffset to, CancellationToken ct)
    {
        var records = new List<ErpRecord>();
        var version = ErpVersion.ForList(await versions.GetV2PercentAsync(ct));
        for (var page = 1; ; page++)
        {
            var query = $"?from={Uri.EscapeDataString(from.ToString("O"))}&to={Uri.EscapeDataString(to.ToString("O"))}" +
                        $"&page={page}&pageSize={ListPageSize}";
            try
            {
                using var response = await RequestAsync(version, v => http.GetAsync(Invoices(v) + query, ct));
                if (response.StatusCode != HttpStatusCode.OK)
                    return ListFailed($"GET {(int)response.StatusCode} {response.ReasonPhrase} döndü (sayfa {page}).");

                var body = await response.Content.ReadFromJsonAsync<ErpListPage>(JsonSerializerOptions.Web, ct);
                if (body?.Items is null)
                    return ListFailed($"Sayfa {page} okunamadı: cevap beklenen biçimde değil.");

                records.AddRange(body.Items.Select(i => new ErpRecord(
                    i.InvoiceNumber, i.ErpReference, i.CustomerCode, ReadAmount(i.Amount, i.AmountKurus), i.Currency, i.InvoiceDate, i.ReceivedAt,
                    i.CancelReference is not null)));
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
                invoiceNumber, r.ErpReference, r.CustomerCode, ReadAmount(r.Amount, r.AmountKurus), r.Currency, r.InvoiceDate, r.ReceivedAt,
                answer.CancelReference is not null)).ToList();
        }
        catch (JsonException)
        {
            return null;
        }
    }

    /// <summary>The record's amount whichever version answered; without one the answer is not readable.</summary>
    private static decimal ReadAmount(decimal? amount, long? amountKurus) =>
        amountKurus is { } kurus ? kurus / 100m : amount ?? throw new JsonException("The record has no amount.");

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

    private static ErpSendResult Failed(int? status, string error, Stopwatch watch, ErpNoAnswer? noAnswer = null) =>
        new(false, null, status, error, watch.Elapsed, NoAnswer: noAnswer);

    private static string? ReadString(string body, string field)
    {
        try
        {
            using var json = JsonDocument.Parse(body);
            // TryGetProperty throws on anything but an object ([], null, 42, "x"); such a body has no reference.
            return json.RootElement.ValueKind == JsonValueKind.Object
                   && json.RootElement.TryGetProperty(field, out var value) && value.ValueKind == JsonValueKind.String
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

    private sealed record ErpLookupBody(List<ErpLookupRecord>? Records, string? CancelReference);

    private sealed record ErpLookupRecord(
        string ErpReference, string CustomerCode, decimal? Amount, long? AmountKurus, string Currency, DateOnly InvoiceDate,
        DateTimeOffset ReceivedAt);

    private sealed record ErpListPage(int TotalCount, List<ErpListItem>? Items);

    private sealed record ErpListItem(
        string InvoiceNumber, string ErpReference, string CustomerCode, decimal? Amount, long? AmountKurus, string Currency,
        DateOnly InvoiceDate, DateTimeOffset ReceivedAt, string? CancelReference);

    private sealed record ErpAcceptedRecord(
        string? ErpReference, string? CustomerCode, decimal? Amount, long? AmountKurus, string? Currency, DateOnly? InvoiceDate,
        DateTimeOffset? ReceivedAt);

    private sealed record ErpInvoiceRequest(
        string InvoiceNumber, string CustomerCode, decimal Amount, string Currency, DateOnly InvoiceDate);

    private sealed record ErpInvoiceRequestV2(
        string InvoiceNumber, string CustomerCode, long AmountKurus, string Currency, DateOnly InvoiceDate);
}
