using InvoiceService.Application.Metrics;

namespace InvoiceService.Api.Workers;

/// <summary>
/// Reads the database values of the metrics at startup and then Metrics:DatabaseReadSeconds after the end of each
/// reading, so two readings are never closer than that. Scrapes in between get the last reading, so however often
/// Prometheus scrapes, the database is queried at this pace.
/// </summary>
public sealed class DatabaseMetricsWorker(
    IServiceScopeFactory scopes, IOptions<MetricsOptions> options, ILogger<DatabaseMetricsWorker> logger) : BackgroundService
{
    protected override async Task ExecuteAsync(CancellationToken stoppingToken)
    {
        var interval = TimeSpan.FromSeconds(options.Value.DatabaseReadSeconds);
        logger.LogInformation("Database metrics worker started every={Seconds}s", options.Value.DatabaseReadSeconds);

        try
        {
            while (!stoppingToken.IsCancellationRequested)
            {
                await using (var scope = scopes.CreateAsyncScope())
                    await scope.ServiceProvider.GetRequiredService<DatabaseMetricsReader>().ReadAsync(stoppingToken);

                await Task.Delay(interval, stoppingToken);
            }
        }
        catch (OperationCanceledException) when (stoppingToken.IsCancellationRequested)
        {
            // Stopping.
        }
    }
}
