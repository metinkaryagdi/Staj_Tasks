using System.Diagnostics.Metrics;

namespace ErpSimulator.Application.Tests.Fakes;

/// <summary>Meters scoped to this factory, so a MetricCollector given the factory sees only this test's
/// measurements.</summary>
public sealed class TestMeterFactory : IMeterFactory
{
    private readonly List<Meter> _meters = [];

    public Meter Create(MeterOptions options)
    {
        var meter = new Meter(new MeterOptions(options.Name) { Version = options.Version, Tags = options.Tags, Scope = this });
        _meters.Add(meter);
        return meter;
    }

    public void Dispose() => _meters.ForEach(m => m.Dispose());
}
