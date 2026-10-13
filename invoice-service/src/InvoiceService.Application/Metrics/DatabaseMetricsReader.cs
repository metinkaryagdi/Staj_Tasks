using InvoiceService.Application.Abstractions;
using InvoiceService.Application.Invoices;

namespace InvoiceService.Application.Metrics;

/// <summary>Reads the database values of the metrics once and keeps them in <see cref="DatabaseMetrics"/>.</summary>
public sealed class DatabaseMetricsReader(
    InvoiceQueries queries, IReconciliationStore reconciliation, DatabaseMetrics metrics, ILogger<DatabaseMetricsReader> logger)
{
    public async Task ReadAsync(CancellationToken ct)
    {
        try
        {
            var summary = await queries.SummaryAsync(ct);
            var lastCompleted = await reconciliation.LastCompletedRunAtAsync(ct);
            metrics.Set(new DatabaseReading(summary, lastCompleted));
            logger.LogInformation(
                "Metrics read from the database queued={Queued} oldestQueuedSeconds={Oldest} stuck={Stuck} lastCompletedRun={LastCompleted}",
                summary.QueuedCount, summary.OldestQueuedSeconds?.ToString() ?? "-", summary.StuckCount,
                lastCompleted?.ToString("O") ?? "-");
        }
        catch (Exception ex) when (ex is not OperationCanceledException)
        {
            metrics.Set(null);
            logger.LogWarning("Metrics could not be read from the database: {Message}", ex.GetBaseException().Message);
        }
    }
}
