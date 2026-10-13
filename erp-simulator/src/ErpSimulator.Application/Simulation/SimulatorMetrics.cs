using System.Diagnostics.Metrics;

namespace ErpSimulator.Application.Simulation;

/// <summary>
/// The simulator's metrics (meter <see cref="MeterName"/>), served to Prometheus at /metrics with underscores and
/// _total.
/// </summary>
public sealed class SimulatorMetrics
{
    public const string MeterName = "ErpSimulator";

    private readonly Counter<long> _requests;
    private readonly Counter<long> _rateLimited;

    public SimulatorMetrics(IMeterFactory meterFactory)
    {
        var meter = meterFactory.Create(MeterName);
        _requests = meter.CreateCounter<long>("erp_simulator.invoice_requests", "{request}",
            "Invoice requests a behavior was drawn for, by behavior");
        _rateLimited = meter.CreateCounter<long>("erp_simulator.rate_limited", "{request}",
            "Invoice requests answered 429 by the rate limit, before any behavior was drawn");
    }

    /// <summary>
    /// Every series exists from startup with 0: Prometheus does not count the first value of a new series as an increase.
    /// Called once the app has started, when OpenTelemetry listens; a measurement made before that is lost.
    /// </summary>
    public void StartAtZero()
    {
        foreach (var behavior in Enum.GetValues<Behavior>())
            _requests.Add(0, new KeyValuePair<string, object?>("behavior", behavior.ToString()));
        _rateLimited.Add(0);
    }

    public void BehaviorDrawn(Behavior behavior) =>
        _requests.Add(1, new KeyValuePair<string, object?>("behavior", behavior.ToString()));

    public void RateLimited() => _rateLimited.Add(1);
}
