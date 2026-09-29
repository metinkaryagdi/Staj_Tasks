#:project ../erp-simulator/src/ErpSimulator/ErpSimulator.csproj
// Runs the simulator's own BehaviorSelector without HTTP and prints "<sequence> <behavior>" per line.
// Used by erp-simulator-distribution.sh to check that the behaviors logged over HTTP are exactly
// the sequence the seed should produce.
//
// Usage: dotnet run scripts/erp-simulator-replay.cs -- <count> <seed> <success> <busy> <serverError> <saveThenError> <lateResponse>
using System.Globalization;
using ErpSimulator.Simulation;
using Microsoft.Extensions.Options;

if (args.Length != 7)
{
    Console.Error.WriteLine("Usage: <count> <seed> <success> <busy> <serverError> <saveThenError> <lateResponse>");
    return 1;
}

double Rate(int i) => double.Parse(args[i], CultureInfo.InvariantCulture);

var selector = new BehaviorSelector(Options.Create(new SimulatorOptions
{
    Seed = int.Parse(args[1], CultureInfo.InvariantCulture),
    Rates = new BehaviorRates
    {
        Success = Rate(2), Busy = Rate(3), ServerError = Rate(4), SaveThenError = Rate(5), LateResponse = Rate(6)
    },
    // Only the draw count matters for the sequence; the range just has to be valid.
    RetryAfterMinSeconds = 5,
    RetryAfterMaxSeconds = 30
}));

var count = int.Parse(args[0], CultureInfo.InvariantCulture);
using var output = new StreamWriter(Console.OpenStandardOutput()) { AutoFlush = false, NewLine = "\n" };
for (var i = 0; i < count; i++)
{
    var decision = selector.Next();
    output.WriteLine($"{decision.Sequence} {decision.Behavior}");
}
return 0;
