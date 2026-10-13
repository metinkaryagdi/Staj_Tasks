// Takes Alertmanager's webhook notifications and writes each alert as one log line. There is no e-mail or chat
// integration: the log line is the notification.
using System.Text.Json.Serialization;

var builder = WebApplication.CreateBuilder(args);
builder.Logging.ClearProviders();
builder.Logging.AddSimpleConsole(o =>
{
    o.SingleLine = true;
    o.TimestampFormat = "yyyy-MM-dd HH:mm:ss.fff ";
    o.UseUtcTimestamp = true;
});

var app = builder.Build();
var logger = app.Services.GetRequiredService<ILoggerFactory>().CreateLogger("AlertReceiver");

// One notification can carry several alerts (Alertmanager groups them); each gets its own line.
app.MapPost("/alerts", (AlertmanagerNotification notification) =>
{
    foreach (var alert in notification.Alerts)
    {
        logger.LogWarning(
            "Alert status={Status} alertname={AlertName} startsAt={StartsAt:O} endsAt={EndsAt} " +
            "summary=\"{Summary}\" description=\"{Description}\"",
            alert.Status, alert.Labels.GetValueOrDefault("alertname", "-"), alert.StartsAt, alert.Status == "resolved" ? alert.EndsAt.ToString("O") : "-",
            alert.Annotations.GetValueOrDefault("summary", "-"), alert.Annotations.GetValueOrDefault("description", "-"));
    }
    return Results.Ok();
});

app.Run();

/// <summary>The part of Alertmanager's webhook body (version 4) that is logged.</summary>
internal sealed record AlertmanagerNotification([property: JsonPropertyName("alerts")] List<Alert> Alerts);

/// <param name="Status">firing or resolved.</param>
/// <param name="EndsAt">When it was resolved; only meaningful when <paramref name="Status"/> is resolved.</param>
internal sealed record Alert(
    [property: JsonPropertyName("status")] string Status,
    [property: JsonPropertyName("labels")] Dictionary<string, string> Labels,
    [property: JsonPropertyName("annotations")] Dictionary<string, string> Annotations,
    [property: JsonPropertyName("startsAt")] DateTimeOffset StartsAt,
    [property: JsonPropertyName("endsAt")] DateTimeOffset EndsAt);
