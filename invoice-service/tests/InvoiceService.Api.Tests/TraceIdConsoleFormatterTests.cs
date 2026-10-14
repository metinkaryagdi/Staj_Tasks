using System.Diagnostics;
using InvoiceService.Api.Startup;
using Microsoft.Extensions.Logging;
using Microsoft.Extensions.Logging.Abstractions;

namespace InvoiceService.Api.Tests;

/// <summary>The console line keeps its simple single-line form and ends with the current trace_id.</summary>
public class TraceIdConsoleFormatterTests
{
    private static string Write(string message, Exception? exception = null)
    {
        var entry = new LogEntry<string>(LogLevel.Warning, "InvoiceService.Webhooks", new EventId(0), message, exception, (s, _) => s);
        using var writer = new StringWriter();
        new TraceIdConsoleFormatter().Write(entry, null, writer);
        return writer.ToString();
    }

    [Fact]
    public void A_line_written_in_a_span_ends_with_its_trace_id()
    {
        using var span = new Activity("test").SetIdFormat(ActivityIdFormat.W3C).Start();

        var line = Write("ERP webhook rejected http=401 reason=bad-signature");

        Assert.Matches(@"^\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}\.\d{3} warn: InvoiceService\.Webhooks\[0\] ERP webhook rejected http=401 reason=bad-signature trace_id=[0-9a-f]{32}\r?\n$", line);
        Assert.EndsWith($" trace_id={span.TraceId.ToHexString()}{Environment.NewLine}", line);
    }

    [Fact]
    public void A_line_outside_any_span_says_so_and_an_exception_stays_on_the_same_line()
    {
        Activity.Current = null;

        var line = Write("Outbox send failed", new InvalidOperationException("first\nsecond"));

        Assert.Single(line.Split('\n', StringSplitOptions.RemoveEmptyEntries));
        Assert.Contains("Outbox send failed System.InvalidOperationException: first second", line);
        Assert.EndsWith($" trace_id=-{Environment.NewLine}", line);
    }
}
