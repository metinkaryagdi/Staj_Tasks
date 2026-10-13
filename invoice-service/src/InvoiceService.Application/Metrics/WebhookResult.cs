using InvoiceService.Domain.Webhooks;

namespace InvoiceService.Application.Metrics;

/// <summary>The result label of erp_webhooks.received.</summary>
public static class WebhookResult
{
    public const string Processed = "processed";
    public const string Waiting = "waiting";
    public const string Ignored = "ignored";
    public const string Unauthorized = "401";
    public const string Unavailable = "503";

    public static readonly string[] All = [Processed, Waiting, Ignored, Unauthorized, Unavailable];

    /// <summary>The label for an event stored by this delivery, from its status.</summary>
    public static string Of(string eventStatus) => eventStatus switch
    {
        WebhookEventStatus.Processed => Processed,
        WebhookEventStatus.Pending => Waiting,
        WebhookEventStatus.Ignored => Ignored,
        _ => throw new ArgumentOutOfRangeException(nameof(eventStatus), eventStatus, "Unknown event status.")
    };
}
