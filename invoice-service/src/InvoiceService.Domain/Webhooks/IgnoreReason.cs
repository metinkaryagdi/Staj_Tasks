namespace InvoiceService.Domain.Webhooks;

/// <summary>Why an event was Yok Sayıldı (erp_webhook_events.ignore_reason).</summary>
public static class IgnoreReason
{
    /// <summary>invoice.received after the decision (Onaylandı / Reddedildi): it would move the invoice back.</summary>
    public const string Backward = "Geri Götürüyor";

    /// <summary>A decision for an invoice that already has one: Onaylandı and Reddedildi are final.</summary>
    public const string Final = "Kesin Durumda";

    /// <summary>A second invoice.received while İşleme Alındı: not backwards, but not forward either.</summary>
    public const string NotForward = "İlerletmiyor";

    /// <summary>The event's erp_reference is not the invoice's: it is not about the record the service sent.</summary>
    public const string ReferenceMismatch = "Referans Farklı";

    /// <summary>Waiting for an invoice the service never got, longer than
    /// Reconciliation:UnknownEventAfterMinutes.</summary>
    public const string UnknownInvoice = "Fatura Yok";

    public static readonly string[] All = [Backward, Final, NotForward, ReferenceMismatch, UnknownInvoice];
}
