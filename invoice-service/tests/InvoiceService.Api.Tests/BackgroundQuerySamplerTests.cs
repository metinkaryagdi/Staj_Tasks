using System.Diagnostics;
using InvoiceService.Api.Startup;
using OpenTelemetry;
using OpenTelemetry.Trace;

namespace InvoiceService.Api.Tests;

/// <summary>
/// The sampler as Program.cs uses it (ParentBasedSampler over BackgroundQuerySampler): a database or HTTP call made outside
/// every request and step is not recorded, nor anything under it; requests, steps and the calls they make are.
/// </summary>
public sealed class BackgroundQuerySamplerTests : IDisposable
{
    private readonly ActivitySource _source = new($"sampler-test-{Guid.NewGuid():N}");
    private readonly TracerProvider _provider;

    public BackgroundQuerySamplerTests() => _provider = Sdk.CreateTracerProviderBuilder()
        .AddSource(_source.Name)
        .SetSampler(new ParentBasedSampler(new BackgroundQuerySampler()))
        .Build()!;

    public void Dispose()
    {
        _provider.Dispose();
        _source.Dispose();
    }

    private Activity? Start(string name, ActivityKind kind)
    {
        // A root span: nothing current.
        Activity.Current = null;
        return _source.StartActivity(name, kind);
    }

    [Fact]
    public void A_call_made_outside_every_request_is_not_recorded_and_nor_is_what_runs_under_it()
    {
        using var query = Start("SELECT outbox", ActivityKind.Client);
        using var child = _source.StartActivity("child", ActivityKind.Client);

        Assert.False(query?.Recorded ?? false);
        Assert.False(child?.Recorded ?? false);
    }

    [Theory]
    [InlineData(ActivityKind.Server)]
    [InlineData(ActivityKind.Internal)]
    public void A_request_or_a_step_is_recorded_and_so_are_the_calls_it_makes(ActivityKind kind)
    {
        using var root = Start("root", kind);
        using var call = _source.StartActivity("SELECT invoices", ActivityKind.Client);

        Assert.True(root!.Recorded);
        Assert.True(call!.Recorded);
        Assert.Equal(root.TraceId, call.TraceId);
    }

    [Fact]
    public void A_request_whose_caller_did_not_record_it_is_not_recorded()
    {
        // The traceparent of a call that was not recorded arrives with the sampled flag off.
        var notSampled = new ActivityContext(ActivityTraceId.CreateRandom(), ActivitySpanId.CreateRandom(), ActivityTraceFlags.None, isRemote: true);
        Activity.Current = null;

        using var request = _source.StartActivity("GET /api/v1/invoices", ActivityKind.Server, notSampled);

        Assert.False(request?.Recorded ?? false);
    }
}
