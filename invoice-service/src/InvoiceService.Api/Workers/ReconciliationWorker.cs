using InvoiceService.Application.Reconciliation;

namespace InvoiceService.Api.Workers;

/// <summary>
/// Starts a reconciliation run every Reconciliation:IntervalMinutes, the first one that long after the service starts.
/// If another run holds the lock (the endpoint, or another copy of the service) this tick does nothing.
/// </summary>
public sealed class ReconciliationWorker(
    ReconciliationService service, IOptions<ReconciliationOptions> options, ILogger<ReconciliationWorker> logger) : BackgroundService
{
    protected override async Task ExecuteAsync(CancellationToken stoppingToken)
    {
        var interval = TimeSpan.FromMinutes(options.Value.IntervalMinutes);
        logger.LogInformation("Reconciliation worker started interval={Interval}min", options.Value.IntervalMinutes);

        using var timer = new PeriodicTimer(interval);
        try
        {
            while (await timer.WaitForNextTickAsync(stoppingToken))
            {
                try
                {
                    var started = await service.TryStartAsync(stoppingToken);
                    if (started is null)
                        logger.LogInformation("Reconciliation tick skipped: another run holds the lock");
                    else
                        await service.ExecuteAsync(started, stoppingToken);
                }
                catch (Exception ex) when (ex is not OperationCanceledException)
                {
                    logger.LogWarning("Reconciliation tick failed: {Message}", ex.Message);
                }
            }
        }
        catch (OperationCanceledException) when (stoppingToken.IsCancellationRequested)
        {
            // Stopping.
        }
    }
}
