using InvoiceService.Application.Invoices;

namespace InvoiceService.Api.Invoices;

/// <summary>
/// What happened to one invoice. <see cref="Result"/> is queued, not_found, not_failed or error;
/// <see cref="CurrentStatus"/> is the invoice's status for not_failed.
/// </summary>
public sealed record BulkResendItemResponse(string InvoiceNumber, string Result, string? CurrentStatus)
{
    public static BulkResendItemResponse From(BulkResendItem i) => new(i.InvoiceNumber, CodeOf(i.Outcome), i.CurrentStatus);

    private static string CodeOf(BulkResendOutcome outcome) => outcome switch
    {
        BulkResendOutcome.Queued => "queued",
        BulkResendOutcome.NotFound => "not_found",
        BulkResendOutcome.NotFailed => "not_failed",
        _ => "error"
    };
}

/// <summary>One result per distinct invoice number, in the order the numbers were sent.</summary>
public sealed record BulkResendResponse(IReadOnlyList<BulkResendItemResponse> Results);

/// <summary>The machine-readable <c>code</c> of the problems the screen explains in its own words.</summary>
public static class ProblemCodes
{
    public const string InvoiceNotFound = "invoice_not_found";
    public const string InvoiceNotFailed = "invoice_not_failed";
    public const string ReconciliationRunning = "reconciliation_running";
    public const string OperatorNameRequired = "operator_name_required";
    public const string OperatorNameInvalid = "operator_name_invalid";
    public const string InvoiceNotStuck = "invoice_not_stuck";
    public const string FollowUpOpen = "follow_up_open";
    public const string FollowUpNotOpen = "follow_up_not_open";
}
