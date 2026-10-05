namespace InvoiceService.Domain.Reconciliation;

/// <summary>One reconciliation run (reconciliation_runs): the service's invoices compared with the ERP's
/// records.</summary>
public sealed class ReconciliationRun
{
    public long Id { get; set; }

    public DateTimeOffset StartedAt { get; set; }

    /// <summary>Null while the run is Çalışıyor.</summary>
    public DateTimeOffset? FinishedAt { get; set; }

    /// <summary>One of <see cref="ReconciliationStatus"/>, enforced by a check constraint.</summary>
    public required string Status { get; set; }

    /// <summary>Distinct invoice numbers compared.</summary>
    public int CheckedCount { get; set; }

    /// <summary>Findings the run fixed (Düzeltildi).</summary>
    public int FixedCount { get; set; }

    /// <summary>Findings the run only reported (Raporlandı).</summary>
    public int ReportedCount { get; set; }

    /// <summary>Why the run failed; null unless it is Başarısız.</summary>
    public string? Error { get; set; }
}

public static class ReconciliationStatus
{
    public const string Running = "Çalışıyor";
    public const string Completed = "Tamamlandı";
    public const string Failed = "Başarısız";

    public static readonly string[] All = [Running, Completed, Failed];
}
