namespace InvoiceService.Application.Abstractions;

/// <summary>
/// Keeps the invoice POSTs of every running service copy together under Outbox:SendsPerSecond: each send waits for its
/// own turn, turns are spaced evenly. Lookups (GET) are not paced: the ERP limits only the endpoint that takes invoices.
/// </summary>
public interface IErpSendPacer
{
    /// <summary>Takes the next free turn (shared by all copies) and returns when it has come.</summary>
    Task WaitForTurnAsync(CancellationToken ct);
}
