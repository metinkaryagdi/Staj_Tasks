using InvoiceService.Application.Outbox;
using InvoiceService.Application.Reconciliation;
using InvoiceService.Application.Webhooks;
using InvoiceService.Infrastructure.Erp;

namespace InvoiceService.Api.Startup;

public static class SettingsLogger
{
    public static void LogErpSettings(this WebApplication app)
    {
        var erp = app.Services.GetRequiredService<IOptions<ErpOptions>>().Value;
        var outbox = app.Services.GetRequiredService<IOptions<OutboxOptions>>().Value;
        app.Logger.LogInformation(
            "ERP settings: baseUrl={BaseUrl} timeout={Timeout}s maxConcurrentSends={Max} sendsPerSecond={SendsPerSecond} (all copies) maxAttempts={MaxAttempts} " +
            "backoff=2^n s (max {MaxBackoff}s with jitter up to {MaxJitter}ms) 429=Retry-After lock={Lock}s idleDelay={Idle}ms",
            erp.BaseUrl, erp.TimeoutSeconds, outbox.MaxConcurrentSends, outbox.SendsPerSecond, outbox.MaxAttempts, outbox.MaxBackoffSeconds,
            outbox.MaxJitterMilliseconds, outbox.LockSeconds, outbox.IdleDelayMilliseconds);

        // The secret itself is never logged.
        var webhooks = app.Services.GetRequiredService<IOptions<WebhookOptions>>().Value;
        app.Logger.LogInformation(
            "ERP webhook settings: tolerance={Tolerance}s maxBody={MaxBody} bytes responseBudget={Budget}ms lockTimeout={LockTimeout}ms",
            webhooks.ToleranceSeconds, webhooks.MaxBodyBytes, webhooks.ResponseBudgetMilliseconds, webhooks.LockTimeoutMilliseconds);

        var reconciliation = app.Services.GetRequiredService<IOptions<ReconciliationOptions>>().Value;
        app.Logger.LogInformation(
            "Reconciliation settings: interval={Interval}min lookback={Lookback}h stuckAfter={Stuck}min unknownEventAfter={Unknown}min " +
            "noDecisionAfter={NoDecision}min notFoundRecheck={NotFoundRecheck}h",
            reconciliation.IntervalMinutes, reconciliation.LookbackHours, reconciliation.StuckAfterMinutes, reconciliation.UnknownEventAfterMinutes,
            reconciliation.NoDecisionAfterMinutes, reconciliation.NotFoundRecheckHours);
    }
}
