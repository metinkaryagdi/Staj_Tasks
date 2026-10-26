using System.Text.Json;
using InvoiceService.Application.Webhooks;
using InvoiceService.Domain.Webhooks;
using InvoiceService.IntegrationTests.Support;
using Microsoft.Extensions.Configuration;
using Microsoft.Extensions.DependencyInjection;

namespace InvoiceService.IntegrationTests;

/// <summary>
/// The role rules with real Keycloak tokens: every reading, intervention and invoice creation endpoint, the webhook and
/// /health, each answered for each of the four callers. The invoice and run asked for do not exist, so 404 (or the answer
/// the endpoint gives with nothing to work on) means the role rule let the caller through and 403 means it did not. The
/// webhook is signed correctly, so its answer depends on the signature alone, not on the token.
/// </summary>
public class RoleRuleTests(PostgresFixture postgres, KeycloakFixture keycloak) : AuthTest(postgres, keycloak)
{
    [Theory]
    // Reading: viewer or operator.
    [InlineData("fatura listesi", "izleyici", 200)]
    [InlineData("fatura listesi", "operator", 200)]
    [InlineData("fatura listesi", "rolsuz", 403)]
    [InlineData("fatura listesi", "siparis-sistemi", 403)]
    [InlineData("özet", "izleyici", 200)]
    [InlineData("özet", "operator", 200)]
    [InlineData("özet", "rolsuz", 403)]
    [InlineData("özet", "siparis-sistemi", 403)]
    [InlineData("fatura", "izleyici", 404)]
    [InlineData("fatura", "operator", 404)]
    [InlineData("fatura", "rolsuz", 403)]
    [InlineData("fatura", "siparis-sistemi", 403)]
    [InlineData("fatura detayı", "izleyici", 404)]
    [InlineData("fatura detayı", "operator", 404)]
    [InlineData("fatura detayı", "rolsuz", 403)]
    [InlineData("fatura detayı", "siparis-sistemi", 403)]
    [InlineData("mutabakat listesi", "izleyici", 200)]
    [InlineData("mutabakat listesi", "operator", 200)]
    [InlineData("mutabakat listesi", "rolsuz", 403)]
    [InlineData("mutabakat listesi", "siparis-sistemi", 403)]
    [InlineData("mutabakat detayı", "izleyici", 404)]
    [InlineData("mutabakat detayı", "operator", 404)]
    [InlineData("mutabakat detayı", "rolsuz", 403)]
    [InlineData("mutabakat detayı", "siparis-sistemi", 403)]
    // Intervention: operator only.
    [InlineData("yeniden gönderme", "izleyici", 403)]
    [InlineData("yeniden gönderme", "operator", 404)]
    [InlineData("yeniden gönderme", "rolsuz", 403)]
    [InlineData("yeniden gönderme", "siparis-sistemi", 403)]
    [InlineData("toplu yeniden gönderme", "izleyici", 403)]
    [InlineData("toplu yeniden gönderme", "operator", 200)]
    [InlineData("toplu yeniden gönderme", "rolsuz", 403)]
    [InlineData("toplu yeniden gönderme", "siparis-sistemi", 403)]
    [InlineData("takibe alma", "izleyici", 403)]
    [InlineData("takibe alma", "operator", 404)]
    [InlineData("takibe alma", "rolsuz", 403)]
    [InlineData("takibe alma", "siparis-sistemi", 403)]
    [InlineData("takibi kapatma", "izleyici", 403)]
    [InlineData("takibi kapatma", "operator", 409)] // no open follow-up to close
    [InlineData("takibi kapatma", "rolsuz", 403)]
    [InlineData("takibi kapatma", "siparis-sistemi", 403)]
    [InlineData("mutabakat başlatma", "izleyici", 403)]
    [InlineData("mutabakat başlatma", "operator", 202)]
    [InlineData("mutabakat başlatma", "rolsuz", 403)]
    [InlineData("mutabakat başlatma", "siparis-sistemi", 403)]
    // Invoice creation: the order system only.
    [InlineData("fatura oluşturma", "izleyici", 403)]
    [InlineData("fatura oluşturma", "operator", 403)]
    [InlineData("fatura oluşturma", "rolsuz", 403)]
    [InlineData("fatura oluşturma", "siparis-sistemi", 202)]
    // No token needed.
    [InlineData("webhook", "izleyici", 200)]
    [InlineData("webhook", "operator", 200)]
    [InlineData("webhook", "rolsuz", 200)]
    [InlineData("webhook", "siparis-sistemi", 200)]
    [InlineData("health", "izleyici", 200)]
    [InlineData("health", "operator", 200)]
    [InlineData("health", "rolsuz", 200)]
    [InlineData("health", "siparis-sistemi", 200)]
    public async Task Each_endpoint_answers_each_token_by_its_role(string endpoint, string caller, int expected)
    {
        var token = caller == "siparis-sistemi"
            ? await Keycloak.OrderSystemTokenAsync()
            : await Keycloak.UserTokenAsync(caller);

        var response = endpoint switch
        {
            "fatura listesi" => await SendAsync(HttpMethod.Get, "/api/v1/invoices", token),
            "özet" => await SendAsync(HttpMethod.Get, "/api/v1/invoices/summary", token),
            "fatura" => await SendAsync(HttpMethod.Get, "/api/v1/invoices/FTR-999999", token),
            "fatura detayı" => await SendAsync(HttpMethod.Get, "/api/v1/invoices/FTR-999999/details", token),
            "mutabakat listesi" => await SendAsync(HttpMethod.Get, "/api/v1/reconciliation-runs", token),
            "mutabakat detayı" => await SendAsync(HttpMethod.Get, "/api/v1/reconciliation-runs/999999", token),
            "yeniden gönderme" => await SendAsync(HttpMethod.Post, "/api/v1/invoices/FTR-999999/resend", token),
            "toplu yeniden gönderme" => await SendAsync(HttpMethod.Post, "/api/v1/invoices/resend", token,
                new { invoiceNumbers = new[] { "FTR-999999" } }),
            "takibe alma" => await SendAsync(HttpMethod.Post, "/api/v1/invoices/FTR-999999/follow-up", token,
                new { note = "kontrol" }),
            "takibi kapatma" => await SendAsync(HttpMethod.Post, "/api/v1/invoices/FTR-999999/follow-up/close", token),
            "mutabakat başlatma" => await SendAsync(HttpMethod.Post, "/api/v1/reconciliation-runs", token),
            "fatura oluşturma" => await SendAsync(HttpMethod.Post, "/api/v1/invoices", token,
                new CreateInvoiceBody("C1", 10m, "TRY", "2026-10-26")),
            "webhook" => await SendWebhookAsync(token),
            "health" => await SendAsync(HttpMethod.Get, "/health", token),
            _ => throw new ArgumentOutOfRangeException(nameof(endpoint), endpoint, null)
        };

        Assert.Equal(expected, (int)response.StatusCode);
    }

    /// <summary>An ERP event signed the way the ERP signs it, with the token added as well.</summary>
    private async Task<HttpResponseMessage> SendWebhookAsync(string token)
    {
        var secret = Service.Services.GetRequiredService<IConfiguration>()["ErpWebhooks:Secret"]!;
        var body = JsonSerializer.SerializeToUtf8Bytes(new ErpWebhookRequest(
            Guid.NewGuid().ToString(), WebhookEventType.Approved, "FTR-999999", "ERP-FTR-999999", DateTimeOffset.UtcNow, null));
        var timestamp = DateTimeOffset.UtcNow.ToUnixTimeSeconds().ToString();

        using var client = Service.CreateClient();
        var request = new HttpRequestMessage(HttpMethod.Post, "/api/v1/erp-webhooks") { Content = new ByteArrayContent(body) };
        request.Content.Headers.ContentType = new("application/json");
        request.Headers.Add(WebhookSignature.TimestampHeader, timestamp);
        request.Headers.Add(WebhookSignature.SignatureHeader, WebhookSignature.Compute(secret, timestamp, body));
        request.Headers.Authorization = new("Bearer", token);
        return await client.SendAsync(request);
    }

    private sealed record CreateInvoiceBody(string CustomerCode, decimal Amount, string Currency, string InvoiceDate);
}
