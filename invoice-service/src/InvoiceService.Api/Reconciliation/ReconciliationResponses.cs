using InvoiceService.Domain.Reconciliation;

namespace InvoiceService.Api.Reconciliation;

/// <summary>One reconciliation run as the service stores it.</summary>
public sealed record ReconciliationRunResponse(
    long Id,
    DateTimeOffset StartedAt,
    DateTimeOffset? FinishedAt,
    string Status,
    int CheckedCount,
    int FixedCount,
    int ReportedCount,
    string? Error)
{
    public static ReconciliationRunResponse From(ReconciliationRun r) => new(
        r.Id, r.StartedAt, r.FinishedAt, r.Status, r.CheckedCount, r.FixedCount, r.ReportedCount, r.Error);
}

public sealed record ReconciliationFindingResponse(
    long Id, string InvoiceNumber, string FindingType, string Action, string Details, DateTimeOffset CreatedAt)
{
    public static ReconciliationFindingResponse From(ReconciliationFinding f) => new(
        f.Id, f.InvoiceNumber, f.FindingType, f.Action, f.Details, f.CreatedAt);
}

/// <summary>A run with what it found.</summary>
public sealed record ReconciliationRunDetailResponse(ReconciliationRunResponse Run, IReadOnlyList<ReconciliationFindingResponse> Findings);
