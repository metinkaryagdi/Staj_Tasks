namespace InvoiceService.Domain.Reconciliation;

/// <summary>One difference a run found between the service and the ERP (reconciliation_findings).</summary>
public sealed class ReconciliationFinding
{
    public long Id { get; set; }

    public long RunId { get; set; }

    /// <summary>No foreign key to invoices: the ERP may have an invoice the service does not know.</summary>
    public required string InvoiceNumber { get; set; }

    /// <summary>One of <see cref="Reconciliation.FindingType"/>, enforced by a check constraint.</summary>
    public required string FindingType { get; set; }

    /// <summary>One of <see cref="FindingAction"/>; Düzeltildi only for the types the run fixes.</summary>
    public required string Action { get; set; }

    /// <summary>What was found and, if fixed, what changed.</summary>
    public required string Details { get; set; }

    public DateTimeOffset CreatedAt { get; set; }
}

public static class FindingAction
{
    public const string Fixed = "Düzeltildi";
    public const string Reported = "Raporlandı";

    public static readonly string[] All = [Fixed, Reported];
}

public static class FindingType
{
    /// <summary>Gönderildi or İşleme Alındı for longer than the threshold; the ERP's decision is applied.
    /// Fixed.</summary>
    public const string StuckInvoice = "Takılı Fatura";

    /// <summary>Başarısız here, but the ERP has it: Gönderildi with the ERP's reference (and its decision).
    /// Fixed.</summary>
    public const string FailedButInErp = "Başarısız Ama ERP Kayıtlı";

    /// <summary>
    /// A waiting event for an invoice the service does not know, older than the threshold: Yok Sayıldı. Fixed.
    /// </summary>
    public const string UnknownEvent = "Tanınmayan Haber";

    /// <summary>The ERP has the invoice, the service does not. Reported.</summary>
    public const string MissingInService = "Serviste Yok";

    /// <summary>The service says it was sent, the ERP has no record. Reported.</summary>
    public const string MissingInErp = "ERP Kaydı Yok";

    /// <summary>The ERP has more than one record of the invoice number. Reported.</summary>
    public const string DuplicateInErp = "ERP Çift Kayıt";

    /// <summary>Amount, currency, customer code or erp_reference differ. Reported.</summary>
    public const string FieldMismatch = "Alan Farkı";

    /// <summary>
    /// Stuck longer than the no-decision threshold and the ERP, asked, has still decided nothing that moves it. Reported,
    /// again in every run while it lasts; the invoice is fixed by the first run after the decision comes.
    /// </summary>
    public const string NoErpDecision = "ERP Karar Vermedi";

    public static readonly string[] All =
        [StuckInvoice, FailedButInErp, UnknownEvent, MissingInService, MissingInErp, DuplicateInErp, FieldMismatch, NoErpDecision];

    /// <summary>The types a run fixes; every other type is only reported.</summary>
    public static readonly string[] Fixable = [StuckInvoice, FailedButInErp, UnknownEvent];
}
