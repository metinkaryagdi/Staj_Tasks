using System.Diagnostics;
using OpenTelemetry.Trace;

namespace InvoiceService.Api.Startup;

/// <summary>
/// The root sampler: a trace whose first span is a database or HTTP call made outside every request and step is not
/// recorded. Those are the background workers' queries (the outbox queue, the metrics readings, the scheduled
/// reconciliation's lookups); none of them names an invoice, so the Collector would never keep them, only hold each one for its whole
/// decision wait. Everything else starts a recorded trace. Used under ParentBasedSampler: spans with a parent follow
/// the parent's decision, so the children of a dropped call are dropped too, and the ERP simulator drops a call that
/// arrives from one.
/// </summary>
public sealed class BackgroundQuerySampler : Sampler
{
    public override SamplingResult ShouldSample(in SamplingParameters samplingParameters) =>
        new(samplingParameters.Kind == ActivityKind.Client ? SamplingDecision.Drop : SamplingDecision.RecordAndSample);
}
