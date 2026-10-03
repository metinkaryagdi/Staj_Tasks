namespace ErpSimulator.Api.Startup;

public static class LoggingExtensions
{
    /// <summary>One line per entry on the console, UTC timestamps; no other log providers.</summary>
    public static WebApplicationBuilder AddConsoleLogging(this WebApplicationBuilder builder)
    {
        builder.Logging.ClearProviders();
        builder.Logging.AddSimpleConsole(o =>
        {
            o.SingleLine = true;
            o.TimestampFormat = "yyyy-MM-dd HH:mm:ss.fff ";
            o.UseUtcTimestamp = true;
        });
        return builder;
    }
}
