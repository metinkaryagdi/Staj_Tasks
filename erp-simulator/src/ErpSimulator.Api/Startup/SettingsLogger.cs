using ErpSimulator.Application.Simulation;
using ErpSimulator.Application.Webhooks;

namespace ErpSimulator.Api.Startup;

public static class SettingsLogger
{
    public static void LogSimulatorSettings(this WebApplication app)
    {
        var simulator = app.Services.GetRequiredService<IOptions<SimulatorOptions>>().Value;
        var rates = simulator.Rates;
        string Pct(double rate) => rate.ToString(System.Globalization.CultureInfo.InvariantCulture);

        app.Logger.LogInformation(
            "Simulator settings: seed={Seed} success={Success}% busy={Busy}% serverError={ServerError}% " +
            "saveThenError={SaveThenError}% lateResponse={LateResponse}% (total={Total}) lateDelay={LateDelay}s " +
            "retryAfter={RetryMin}-{RetryMax}s format={RetryFormat} idempotentInvoices={IdempotentInvoices} " +
            "processing={ProcessingMin}-{ProcessingMax}ms",
            simulator.Seed, Pct(rates.Success), Pct(rates.Busy), Pct(rates.ServerError), Pct(rates.SaveThenError), Pct(rates.LateResponse), rates.Total,
            simulator.LateResponseDelaySeconds, simulator.RetryAfterMinSeconds, simulator.RetryAfterMaxSeconds, simulator.RetryAfterFormat,
            simulator.IdempotentInvoices, simulator.ProcessingMinMilliseconds, simulator.ProcessingMaxMilliseconds);

        var rateLimit = app.Services.GetRequiredService<IOptions<RateLimitOptions>>().Value;
        app.Logger.LogInformation("Rate limit: {PermitsPerSecond} invoice requests per second, shared by every client",
            rateLimit.PermitsPerSecond);

        // The secret itself is never logged.
        var webhooks = app.Services.GetRequiredService<IOptions<WebhookOptions>>().Value;
        app.Logger.LogInformation(
            "Webhook settings: enabled={Enabled} target={Target} timeout={Timeout}s retries={Retries}s first={FirstMin}-{FirstMax}s " +
            "second={SecondMin}-{SecondMax}s approval={Approval}% maxConcurrent={Max}",
            webhooks.Enabled, webhooks.TargetUrl, webhooks.TimeoutSeconds, string.Join(",", webhooks.RetryDelaysSeconds), webhooks.FirstEventMinSeconds, webhooks.FirstEventMaxSeconds,
            webhooks.SecondEventMinSeconds, webhooks.SecondEventMaxSeconds, Pct(webhooks.ApprovalRate), webhooks.MaxConcurrentSends);

        var problems = webhooks.Problems;
        app.Logger.LogInformation(
            "Webhook problems: duplicate={Duplicate}% orderMix={OrderMix}% lostDecision={Lost}% fake={Fake}% replay={Replay}% replayAge={ReplayAge}s",
            Pct(problems.DuplicateRate), Pct(problems.OrderMixRate), Pct(problems.LostDecisionRate), Pct(problems.FakeRate), Pct(problems.ReplayRate), problems.ReplayAgeSeconds);
    }
}
