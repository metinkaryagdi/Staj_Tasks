namespace InvoiceService.Domain.Operators;

/// <summary>
/// One intervention made from the operations screen (operator_actions): who made it, what it was, on which invoice and
/// how it ended. The name is what the person typed into the screen; it is a record, not an identity.
/// </summary>
public sealed class OperatorAction
{
    /// <summary>The longest name accepted; a name is a few words.</summary>
    public const int MaxNameLength = 100;

    /// <summary>The longest invoice number stored; a longer one in a request cannot be an invoice and is cut.</summary>
    public const int MaxInvoiceNumberLength = 64;

    /// <summary>The result column's length; a result that names someone is cut to fit.</summary>
    public const int MaxResultLength = 128;

    public long Id { get; set; }

    public required string OperatorName { get; set; }

    /// <summary>One of <see cref="OperatorActionType"/>, enforced by a check constraint.</summary>
    public required string Action { get; set; }

    /// <summary>The invoice the action was about; null only for <see cref="OperatorActionType.StartReconciliation"/>.</summary>
    public string? InvoiceNumber { get; set; }

    /// <summary>How the action ended, for example <see cref="OperatorActionResult.Queued"/>.</summary>
    public required string Result { get; set; }

    public DateTimeOffset CreatedAt { get; set; }
}

public static class OperatorActionType
{
    public const string Resend = "Yeniden Gönderme";

    /// <summary>One record per invoice of the request.</summary>
    public const string BulkResend = "Toplu Yeniden Gönderme";

    public const string StartReconciliation = "Mutabakat Başlatma";
    public const string FollowUp = "Takibe Alma";
    public const string CloseFollowUp = "Takibi Kapatma";

    public static readonly string[] All = [Resend, BulkResend, StartReconciliation, FollowUp, CloseFollowUp];
}

public static class OperatorActionResult
{
    public const string Queued = "Kuyruğa alındı";
    public const string NotFound = "Fatura bulunamadı";
    public const string Error = "Hata: değişiklik yapılmadı";
    public const string AlreadyRunning = "Reddedildi: başka bir çalışma sürüyor";
    public const string FollowUpOpened = "Takibe alındı";
    public const string FollowUpClosed = "Takip kapatıldı";
    public const string FollowUpNotOpen = "Reddedildi: açık takip yok";
    public const string InvalidNote = "Reddedildi: not geçersiz";

    public static string NotFailed(string currentStatus) => $"Reddedildi: fatura {currentStatus}";

    public static string NotStuck(string currentStatus) => $"Reddedildi: fatura takılı değil ({currentStatus})";

    public static string AlreadyFollowed(string operatorName)
    {
        const string prefix = "Reddedildi: zaten takipte (";
        const string suffix = ")";
        var limit = OperatorAction.MaxResultLength - prefix.Length - suffix.Length;
        return $"{prefix}{operatorName[..Math.Min(operatorName.Length, limit)]}{suffix}";
    }

    public static string RunStarted(long runId) => $"Başlatıldı: çalışma {runId}";
}
