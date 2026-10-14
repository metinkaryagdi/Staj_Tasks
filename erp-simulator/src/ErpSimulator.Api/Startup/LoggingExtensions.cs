using System.Diagnostics;
using Microsoft.Extensions.Logging.Abstractions;
using Microsoft.Extensions.Logging.Console;

namespace ErpSimulator.Api.Startup;

public static class LoggingExtensions
{
    /// <summary>One line per entry on the console, UTC timestamps, the current trace_id at the end; no other log
    /// providers.</summary>
    public static WebApplicationBuilder AddConsoleLogging(this WebApplicationBuilder builder)
    {
        builder.Logging.ClearProviders();
        builder.Logging.AddConsole(o => o.FormatterName = TraceIdConsoleFormatter.FormatterName)
            .AddConsoleFormatter<TraceIdConsoleFormatter, ConsoleFormatterOptions>();
        return builder;
    }
}

/// <summary>
/// The simple console format on one line (<c>2026-10-14 08:28:51.388 info: Category[0] message</c>) followed by
/// <c>trace_id=</c> and the trace of the span current when the entry was written, or <c>-</c> outside any span. The
/// simulator's lines about an invoice carry the invoice's trace, so they are found with the invoice service's.
/// </summary>
public sealed class TraceIdConsoleFormatter() : ConsoleFormatter(FormatterName)
{
    public const string FormatterName = "single-line-trace-id";

    public override void Write<TState>(in LogEntry<TState> logEntry, IExternalScopeProvider? scopeProvider, TextWriter textWriter)
    {
        var message = logEntry.Formatter(logEntry.State, logEntry.Exception);
        if (message is null && logEntry.Exception is null)
            return;

        var line = $"{DateTime.UtcNow:yyyy-MM-dd HH:mm:ss.fff} {Level(logEntry.LogLevel)}: {logEntry.Category}[{logEntry.EventId.Id}] {message}";
        if (logEntry.Exception is not null)
            line += " " + logEntry.Exception;
        // Written while the entry is logged, on the caller's thread: Activity.Current is the caller's span.
        var traceId = Activity.Current?.TraceId.ToHexString() ?? "-";
        textWriter.WriteLine($"{line.ReplaceLineEndings(" ")} trace_id={traceId}");
    }

    private static string Level(LogLevel level) => level switch
    {
        LogLevel.Trace => "trce",
        LogLevel.Debug => "dbug",
        LogLevel.Information => "info",
        LogLevel.Warning => "warn",
        LogLevel.Error => "fail",
        LogLevel.Critical => "crit",
        _ => level.ToString()
    };
}
