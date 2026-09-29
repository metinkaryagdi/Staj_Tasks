#:project ../erp-simulator/src/ErpSimulator/ErpSimulator.csproj
// Runs the simulator's own BehaviorSelector without HTTP and prints "<sequence> <behavior>" per line.
// Used by erp-simulator-distribution.sh to check that the behaviors logged over HTTP are exactly
// the sequence the seed should produce.
//
// Usage: dotnet run scripts/erp-simulator-replay.cs -- <count> <seed> <busy> <serverError> <saveThenError> <lateResponse>
using System.Globalization;
using ErpSimulator.Simulation;
using Microsoft.Extensions.Options;

if (args.Length != 6)
{
    Console.Error.WriteLine("Usage: <count> <seed> <busy> <serverError> <saveThenError> <lateResponse>");
    return 1;
}

double Rate(int i) => double.Parse(args[i], CultureInfo.InvariantCulture);

var selector = new BehaviorSelector(Options.Create(new SimulatorOptions
{
    Seed = int.Parse(args[1], CultureInfo.InvariantCulture),
    Rates = new BehaviorRates { Busy = Rate(2), ServerError = Rate(3), SaveThenError = Rate(4), LateResponse = Rate(5) }
}));

var count = int.Parse(args[0], CultureInfo.InvariantCulture);
using var output = new StreamWriter(Console.OpenStandardOutput()) { AutoFlush = false, NewLine = "\n" };
for (var i = 0; i < count; i++)
{
    var decision = selector.Next();
    output.WriteLine($"{decision.Sequence} {decision.Behavior}");
}
return 0;
