using InvoiceService.Api.Reconciliation;
using InvoiceService.Application.Invoices;
using InvoiceService.Domain.Operators;
using InvoiceService.Domain.Outbox;
using InvoiceService.Domain.Webhooks;
using InvoiceService.Domain.Invoices;

namespace InvoiceService.Api.Invoices;

/// <summary>One page of invoices; <see cref="TotalCount"/> counts every invoice the filters match.</summary>
public sealed record InvoiceListResponse(IReadOnlyList<InvoiceResponse> Items, int Page, int PageSize, int TotalCount, int TotalPages);

public sealed record StatusCountResponse(string Status, int Count);

/// <summary>The number of invoices in each status, how many of them are stuck, and the queue to the ERP.</summary>
public sealed record InvoiceSummaryResponse(
    IReadOnlyList<StatusCountResponse> Counts, int Total, int StuckCount, int StuckAfterMinutes,
    int QueuedCount, long? OldestQueuedSeconds, int SentLastMinute);

/// <summary>The invoice's erp_outbox entry (its internal lock and claim columns are left out).</summary>
public sealed record OutboxEntryResponse(
    string Status, int AttemptCount, DateTimeOffset NextAttemptAt, string? LastError, DateTimeOffset CreatedAt,
    DateTimeOffset? ProcessedAt)
{
    public static OutboxEntryResponse From(ErpOutboxEntry e) => new(
        e.Status, e.AttemptCount, e.NextAttemptAt, e.LastError, e.CreatedAt, e.ProcessedAt);
}

/// <summary>An event the ERP reported about the invoice (without its raw payload).</summary>
public sealed record InvoiceEventResponse(
    string EventId, string EventType, string Status, string? IgnoreReason, int DeliveryCount, DateTimeOffset OccurredAt,
    DateTimeOffset ReceivedAt, DateTimeOffset? ProcessedAt)
{
    public static InvoiceEventResponse From(ErpWebhookEvent e) => new(
        e.EventId, e.EventType, e.Status, e.IgnoreReason, e.DeliveryCount, e.OccurredAt, e.ReceivedAt, e.ProcessedAt);
}

/// <summary>An intervention made from the screen: who, what, how it ended.</summary>
public sealed record OperatorActionResponse(string OperatorName, string Action, string Result, DateTimeOffset CreatedAt)
{
    public static OperatorActionResponse From(OperatorAction a) => new(a.OperatorName, a.Action, a.Result, a.CreatedAt);
}

public sealed record InvoiceFollowUpResponse(
    long Id, string InvoiceNumber, string OperatorName, string Note, DateTimeOffset OpenedAt, DateTimeOffset? ClosedAt, string? ClosedBy)
{
    public static InvoiceFollowUpResponse From(InvoiceFollowUp f) =>
        new(f.Id, f.InvoiceNumber, f.OperatorName, f.Note, f.OpenedAt, f.ClosedAt, f.ClosedBy);
}

public sealed record InvoiceFollowUpSummaryResponse(string OperatorName, string Note, DateTimeOffset OpenedAt);

/// <summary>
/// The invoice, its outbox entry, its events, the reconciliation findings about it and the interventions made on it, in
/// one response.
/// </summary>
public sealed record InvoiceDetailsResponse(
    InvoiceResponse Invoice, OutboxEntryResponse? Outbox, IReadOnlyList<InvoiceEventResponse> Events,
    IReadOnlyList<ReconciliationFindingResponse> Findings, IReadOnlyList<OperatorActionResponse> OperatorActions,
    InvoiceFollowUpSummaryResponse? FollowUp, IReadOnlyList<InvoiceFollowUpResponse> FollowUps)
{
    public static InvoiceDetailsResponse From(InvoiceDetails d) => new(
        InvoiceResponse.From(d.Invoice, d.Stuck),
        d.Outbox is null ? null : OutboxEntryResponse.From(d.Outbox),
        d.Events.Select(InvoiceEventResponse.From).ToList(),
        d.Findings.Select(ReconciliationFindingResponse.From).ToList(),
        d.OperatorActions.Select(OperatorActionResponse.From).ToList(),
        d.FollowUp is null ? null : new(d.FollowUp.OperatorName, d.FollowUp.Note, d.FollowUp.OpenedAt),
        d.FollowUps.Select(InvoiceFollowUpResponse.From).ToList());
}

public sealed record FollowUpRequest(string? Note);
