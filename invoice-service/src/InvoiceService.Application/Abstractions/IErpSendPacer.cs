namespace InvoiceService.Application.Abstractions;

/// <summary>Keeps the invoice POSTs of every service copy together under Outbox:SendsPerSecond; GETs are not paced.</summary>
public interface IErpSendPacer
{
    /// <summary>Takes the next free turn (shared by all copies) and returns when it has come.</summary>
    Task WaitForTurnAsync(CancellationToken ct);
}
