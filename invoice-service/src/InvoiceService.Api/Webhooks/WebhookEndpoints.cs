using System.Text;
using System.Text.Json;
using InvoiceService.Application.Abstractions;
using InvoiceService.Application.Webhooks;

namespace InvoiceService.Api.Webhooks;

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
                "nothing is stored. A valid signature with an invalid body: 400. Otherwise 200: the event is stored once " +
                "(a repeated event_id is not applied again) and applied to the invoice, ignored, or kept until the " +
                "invoice is Gönderildi. Not done within ErpWebhooks:ResponseBudgetMilliseconds (or the invoice's row " +
                "lock not free within LockTimeoutMilliseconds): 503, and the ERP sends the event again.")
            .Accepts<ErpWebhookRequest>("application/json")
            .Produces<EventResult>(StatusCodes.Status200OK)
            .ProducesValidationProblem()
            .ProducesProblem(StatusCodes.Status401Unauthorized)
            .ProducesProblem(StatusCodes.Status413PayloadTooLarge)
            .ProducesProblem(StatusCodes.Status503ServiceUnavailable);
    }

    /// <summary>
    /// The task: the service answers every event within 5 seconds. The answer is due ResponseBudgetMilliseconds after
    /// the request reaches this handler, whatever the database does: the event is stored in its own scope and the
    /// response only waits for it until the budget runs out (then 503). The same budget cancels the work, and
    /// PostgreSQL's lock_timeout / statement_timeout stop it on the server side too.
    /// </summary>
    private static async Task<IResult> ReceiveEvent(
        HttpRequest request, IOptions<WebhookOptions> options, TimeProvider clock, IServiceScopeFactory scopes,
        IDatabaseFailureClassifier database, ILoggerFactory loggerFactory, CancellationToken ct)
    {
        var settings = options.Value;
        var logger = loggerFactory.CreateLogger("InvoiceService.Webhooks");
        var started = clock.GetTimestamp();
        using var budget = new CancellationTokenSource(TimeSpan.FromMilliseconds(settings.ResponseBudgetMilliseconds), clock);
        using var work = CancellationTokenSource.CreateLinkedTokenSource(ct, budget.Token);

        byte[]? body;
        try { body = await WebhookRequestReader.ReadBodyAsync(request, settings.MaxBodyBytes, work.Token); }
        catch (OperationCanceledException) when (budget.IsCancellationRequested)
        {
            return Unavailable(logger, "timeout-reading-body", "-", clock.GetElapsedTime(started));
        }
        if (body is null)
        {
            logger.LogWarning("ERP webhook rejected http=413 reason=too-large maxBytes={Max}", settings.MaxBodyBytes);
            return Results.Problem(statusCode: StatusCodes.Status413PayloadTooLarge, title: "Payload too large");
        }

        // The signature comes first: nothing from an unverified body is parsed or stored.
        var timestamp = WebhookRequestReader.SingleHeader(request, WebhookSignature.TimestampHeader);
        var signature = WebhookRequestReader.SingleHeader(request, WebhookSignature.SignatureHeader);
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

        // The body is valid JSON here, so it is valid UTF-8: stored exactly as received.
        var processing = ProcessInOwnScope(scopes, payload, Encoding.UTF8.GetString(body), work.Token);
        try
        {
            var result = await processing.WaitAsync(budget.Token);
            return Results.Ok(result);
        }
        catch (OperationCanceledException) when (budget.IsCancellationRequested)
        {
            LogLateOutcome(processing, logger, payload.EventId!);
            return Unavailable(logger, "timeout", payload.EventId!, clock.GetElapsedTime(started));
        }
        catch (Exception ex) when (database.TimeoutReason(ex) is { } reason)
        {
            return Unavailable(logger, reason, payload.EventId!, clock.GetElapsedTime(started));
        }
    }

    /// <summary>
    /// Its own DI scope (and DbContext), not the request's: when the budget runs out the response is sent while this
    /// may still be finishing, and the request's scope is disposed with the response.
    /// </summary>
    private static async Task<EventResult> ProcessInOwnScope(
        IServiceScopeFactory scopes, ErpWebhookRequest payload, string body, CancellationToken ct)
    {
        await using var scope = scopes.CreateAsyncScope();
        var processor = scope.ServiceProvider.GetRequiredService<WebhookEventProcessor>();
        return await processor.ReceiveAsync(payload, body, ct);
    }

    /// <summary>
    /// 503: the event was not stored and applied in time. The transaction is rolled back, so the ERP's next delivery
    /// stores it; if it still committed just after the budget ran out, the next delivery is a repeat (200, not applied
    /// again).
    /// </summary>
    private static IResult Unavailable(ILogger logger, string reason, string eventId, TimeSpan elapsed)
    {
        logger.LogWarning("ERP webhook rejected http=503 reason={Reason} event={EventId} elapsed={ElapsedMs}ms",
            reason, eventId, (long)elapsed.TotalMilliseconds);
        return Results.Problem(statusCode: StatusCodes.Status503ServiceUnavailable, title: "Not processed in time");
    }

    /// <summary>After a 503 on timeout: logs whether the work still committed (then a redelivery is a repeat) or not.</summary>
    private static void LogLateOutcome(Task<EventResult> processing, ILogger logger, string eventId) =>
        _ = processing.ContinueWith(t =>
        {
            if (t.IsCompletedSuccessfully)
                logger.LogWarning("ERP webhook event={EventId} committed after its 503; a redelivery is a repeat", eventId);
            else
                logger.LogInformation("ERP webhook event={EventId} rolled back after its 503: {Error}",
                    eventId, t.Exception?.GetBaseException().Message ?? "cancelled");
        }, TaskScheduler.Default);

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
