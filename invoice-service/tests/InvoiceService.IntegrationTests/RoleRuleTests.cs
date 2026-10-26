using System.Text.Json;
using InvoiceService.Application.Webhooks;
using InvoiceService.Domain.Webhooks;
using InvoiceService.IntegrationTests.Support;
using Microsoft.Extensions.Configuration;
using Microsoft.Extensions.DependencyInjection;

namespace InvoiceService.IntegrationTests;

/// <summary>
/// The role rules with real Keycloak tokens: each of the five kinds of endpoint answered for each of the four callers.
/// Resend asks for an invoice that does not exist, so 404 means the role rule let the operator through and 403 means it
/// did not. The webhook is signed correctly, so its answer depends on the signature alone, not on the token.
/// </summary>
public class RoleRuleTests(PostgresFixture postgres, KeycloakFixture keycloak) : AuthTest(postgres, keycloak)
{
    [Theory]
    [InlineData("okuma", "izleyici", 200)]
    [InlineData("okuma", "operator", 200)]
    [InlineData("okuma", "rolsuz", 403)]
    [InlineData("okuma", "siparis-sistemi", 403)]
    [InlineData("müdahale", "izleyici", 403)]
    [InlineData("müdahale", "operator", 404)]
    [InlineData("müdahale", "rolsuz", 403)]
    [InlineData("müdahale", "siparis-sistemi", 403)]
    [InlineData("fatura oluşturma", "izleyici", 403)]
    [InlineData("fatura oluşturma", "operator", 403)]
    [InlineData("fatura oluşturma", "rolsuz", 403)]
    [InlineData("fatura oluşturma", "siparis-sistemi", 202)]
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
            "okuma" => await SendAsync(HttpMethod.Get, "/api/v1/invoices/summary", token),
            "müdahale" => await SendAsync(HttpMethod.Post, "/api/v1/invoices/FTR-999999/resend", token),
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
