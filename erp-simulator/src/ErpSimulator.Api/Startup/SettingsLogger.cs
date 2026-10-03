using ErpSimulator.Application.Simulation;
using ErpSimulator.Application.Webhooks;

namespace ErpSimulator.Api.Startup;

public static class SettingsLogger
{
    public static void LogSimulatorSettings(this WebApplication app)
    {
        var o = app.Services.GetRequiredService<IOptions<SimulatorOptions>>().Value;
        var r = o.Rates;
        string Pct(double rate) => rate.ToString(System.Globalization.CultureInfo.InvariantCulture);

        app.Logger.LogInformation(
            "Simulator settings: seed={Seed} success={Success}% busy={Busy}% serverError={ServerError}% " +
            "saveThenError={SaveThenError}% lateResponse={LateResponse}% (total={Total}) lateDelay={LateDelay}s " +
            "retryAfter={RetryMin}-{RetryMax}s format={RetryFormat} idempotentInvoices={IdempotentInvoices}",
            o.Seed, Pct(r.Success), Pct(r.Busy), Pct(r.ServerError), Pct(r.SaveThenError), Pct(r.LateResponse), r.Total,
            o.LateResponseDelaySeconds, o.RetryAfterMinSeconds, o.RetryAfterMaxSeconds, o.RetryAfterFormat,
            o.IdempotentInvoices);

        // The secret itself is never logged.
        var w = app.Services.GetRequiredService<IOptions<WebhookOptions>>().Value;
        app.Logger.LogInformation(
            "Webhook settings: enabled={Enabled} target={Target} timeout={Timeout}s retries={Retries}s first={FirstMin}-{FirstMax}s " +
            "second={SecondMin}-{SecondMax}s approval={Approval}% maxConcurrent={Max}",
            w.Enabled, w.TargetUrl, w.TimeoutSeconds, string.Join(",", w.RetryDelaysSeconds), w.FirstEventMinSeconds, w.FirstEventMaxSeconds,
            w.SecondEventMinSeconds, w.SecondEventMaxSeconds, Pct(w.ApprovalRate), w.MaxConcurrentSends);

        var p = w.Problems;
        app.Logger.LogInformation(
            "Webhook problems: duplicate={Duplicate}% orderMix={OrderMix}% lostDecision={Lost}% fake={Fake}% replay={Replay}% replayAge={ReplayAge}s",
            Pct(p.DuplicateRate), Pct(p.OrderMixRate), Pct(p.LostDecisionRate), Pct(p.FakeRate), Pct(p.ReplayRate), p.ReplayAgeSeconds);
    }
}
