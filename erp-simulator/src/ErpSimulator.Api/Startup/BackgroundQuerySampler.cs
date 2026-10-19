using System.Diagnostics;
using OpenTelemetry.Trace;

namespace ErpSimulator.Api.Startup;

/// <summary>
/// The root sampler: a trace whose first span is a database or HTTP call made outside every request and step is not
/// recorded. Those are the webhook dispatcher's queue queries; none of them names an invoice, so the Collector would
/// never keep them, only hold each one for its whole decision wait. Everything else starts a recorded trace. Used under
/// ParentBasedSampler: spans with a parent follow the parent's decision, so a request from the invoice service whose
/// trace is not recorded there (a reconciliation lookup) is not recorded here either.
/// </summary>
public sealed class BackgroundQuerySampler : Sampler
{
    public override SamplingResult ShouldSample(in SamplingParameters samplingParameters) =>
        new(samplingParameters.Kind == ActivityKind.Client ? SamplingDecision.Drop : SamplingDecision.RecordAndSample);
}
