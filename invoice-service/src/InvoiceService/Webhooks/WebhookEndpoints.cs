using System.Text.Json;
using Microsoft.Extensions.Options;

namespace InvoiceService.Webhooks;

public static class WebhookEndpoints
{
    public static void MapWebhookEndpoints(this IEndpointRouteBuilder app)
    {
        app.MapPost("/api/v1/erp-webhooks", ReceiveEvent)
            .WithTags("ERP webhooks")
            .WithName("ReceiveErpEvent")
            .WithSummary("An event from the ERP about an invoice (invoice.received / approved / rejected)")
            .WithDescription(
                "Signed with HMAC-SHA256 over \"{X-Erp-Timestamp}.{raw body}\" (timestamp in Unix seconds, signature as hex). " +
                "Missing headers, a wrong signature or a timestamp more than ErpWebhooks:ToleranceSeconds away from now: 401, " +
                "nothing is stored. A valid signature with an invalid body: 400.")
            .Accepts<ErpWebhookRequest>("application/json")
            .Produces(StatusCodes.Status200OK)
            .ProducesValidationProblem()
            .ProducesProblem(StatusCodes.Status401Unauthorized)
            .ProducesProblem(StatusCodes.Status413PayloadTooLarge);
    }

    private static async Task<IResult> ReceiveEvent(
        HttpRequest request, IOptions<WebhookOptions> options, TimeProvider clock, ILoggerFactory loggerFactory,
        CancellationToken ct)
    {
        var settings = options.Value;
        var logger = loggerFactory.CreateLogger("InvoiceService.Webhooks");

        var body = await ReadBody(request, settings.MaxBodyBytes, ct);
        if (body is null)
        {
            logger.LogWarning("ERP webhook rejected http=413 reason=too-large maxBytes={Max}", settings.MaxBodyBytes);
            return Results.Problem(statusCode: StatusCodes.Status413PayloadTooLarge, title: "Payload too large");
        }

        // The signature comes first: nothing from an unverified body is parsed or stored.
        var timestamp = SingleHeader(request, WebhookSignature.TimestampHeader);
        var signature = SingleHeader(request, WebhookSignature.SignatureHeader);
        var check = WebhookSignature.Verify(
            settings.Secret, timestamp, signature, body, clock.GetUtcNow(), settings.ToleranceSeconds);
        if (check != SignatureCheck.Valid)
        {
            // The reason is only logged; the response does not tell the sender which check failed.
            logger.LogWarning("ERP webhook rejected http=401 reason={Reason} timestamp={Timestamp} bodyBytes={Bytes}",
                ReasonText(check), timestamp ?? "-", body.Length);
            return Results.Problem(statusCode: StatusCodes.Status401Unauthorized, title: "Unauthorized");
        }

        ErpWebhookRequest? payload;
        try { payload = JsonSerializer.Deserialize<ErpWebhookRequest>(body, JsonSerializerOptions.Web); }
        catch (JsonException ex)
        {
            logger.LogWarning("ERP webhook rejected http=400 reason=invalid-json error={Error}", ex.Message);
            return Results.ValidationProblem(new Dictionary<string, string[]> { ["body"] = ["Not valid JSON for an ERP event."] });
        }
        if (payload is null)
        {
            logger.LogWarning("ERP webhook rejected http=400 reason=invalid-json error=body is null");
            return Results.ValidationProblem(new Dictionary<string, string[]> { ["body"] = ["Not valid JSON for an ERP event."] });
        }

        var errors = payload.Validate();
        if (errors.Count > 0)
        {
            logger.LogWarning("ERP webhook rejected http=400 reason=invalid-fields event={EventId} fields={Fields}",
                payload.EventId ?? "-", string.Join(",", errors.Keys));
            return Results.ValidationProblem(errors);
        }

        logger.LogInformation("ERP webhook verified event={EventId} type={EventType} invoice={InvoiceNumber} erpReference={ErpReference}",
            payload.EventId, payload.EventType, payload.InvoiceNumber, payload.ErpReference);
        return Results.Ok();
    }

    /// <summary>The raw body, or null if it is larger than <paramref name="maxBytes"/> (read no further than that).</summary>
    private static async Task<byte[]?> ReadBody(HttpRequest request, int maxBytes, CancellationToken ct)
    {
        if (request.ContentLength > maxBytes)
            return null;

        using var buffer = new MemoryStream();
        var chunk = new byte[8192];
        int read;
        while ((read = await request.Body.ReadAsync(chunk, ct)) > 0)
        {
            if (buffer.Length + read > maxBytes)
                return null;
            buffer.Write(chunk, 0, read);
        }
        return buffer.ToArray();
    }

    /// <summary>Null when the header is missing or sent more than once.</summary>
    private static string? SingleHeader(HttpRequest request, string name) =>
        request.Headers.TryGetValue(name, out var values) && values.Count == 1 ? values[0] : null;

    private static string ReasonText(SignatureCheck check) => check switch
    {
        SignatureCheck.MissingHeaders => "missing-headers",
        SignatureCheck.BadTimestamp => "bad-timestamp",
        SignatureCheck.Expired => "expired",
        SignatureCheck.FromFuture => "from-future",
        SignatureCheck.BadSignature => "bad-signature",
        _ => check.ToString()
    };
}
