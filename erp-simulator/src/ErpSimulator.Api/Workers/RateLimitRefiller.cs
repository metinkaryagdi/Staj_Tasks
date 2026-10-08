using ErpSimulator.Application.Simulation;

namespace ErpSimulator.Api.Workers;

/// <summary>Refills the invoice rate limit bucket at the start of every clock second (UTC).</summary>
public sealed class RateLimitRefiller(InvoiceRateLimiter limiter, TimeProvider time) : BackgroundService
{
    protected override async Task ExecuteAsync(CancellationToken stoppingToken)
    {
        try
        {
            while (!stoppingToken.IsCancellationRequested)
            {
                var next = InvoiceRateLimiter.NextSecond(time.GetUtcNow());
                // A timer may fire a little early; never refill before the second has started.
                TimeSpan wait;
                while ((wait = next - time.GetUtcNow()) > TimeSpan.Zero)
                    await Task.Delay(wait, time, stoppingToken);
                limiter.Refill();
            }
        }
        catch (OperationCanceledException) when (stoppingToken.IsCancellationRequested)
        {
            // Stopping.
        }
    }
}
