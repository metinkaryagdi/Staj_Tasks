using ErpSimulator.Data;
using ErpSimulator.Invoices;
using ErpSimulator.Simulation;
using Microsoft.EntityFrameworkCore;
using Microsoft.Extensions.Options;

var builder = WebApplication.CreateBuilder(args);

builder.Logging.ClearProviders();
builder.Logging.AddSimpleConsole(o =>
{
    o.SingleLine = true;
    o.TimestampFormat = "yyyy-MM-dd HH:mm:ss.fff ";
    o.UseUtcTimestamp = true;
});

builder.Services.AddOptions<SimulatorOptions>()
    .Bind(builder.Configuration.GetSection(SimulatorOptions.SectionName))
    .ValidateOnStart();
builder.Services.AddSingleton<IValidateOptions<SimulatorOptions>, SimulatorOptionsValidator>();
builder.Services.AddSingleton<BehaviorSelector>();

builder.Services.AddDbContext<ErpDbContext>(o =>
    o.UseNpgsql(builder.Configuration.GetConnectionString("ErpDb")));

builder.Services.AddProblemDetails();

var app = builder.Build();

await MigrateDatabase(app);
LogSimulatorSettings(app);

app.UseExceptionHandler();
app.UseStatusCodePages();

app.MapGet("/health", () => Results.Ok(new { status = "ok" }));
app.MapInvoiceEndpoints();

app.Run();

static async Task MigrateDatabase(WebApplication app)
{
    var logger = app.Logger;
    for (var attempt = 1; ; attempt++)
    {
        try
        {
            await using var scope = app.Services.CreateAsyncScope();
            var db = scope.ServiceProvider.GetRequiredService<ErpDbContext>();
            await db.Database.MigrateAsync();
            return;
        }
        catch (Exception ex) when (attempt < 10)
        {
            logger.LogWarning("Database not ready (attempt {Attempt}/10): {Message}", attempt, ex.Message);
            await Task.Delay(TimeSpan.FromSeconds(2));
        }
    }
}

static void LogSimulatorSettings(WebApplication app)
{
    var o = app.Services.GetRequiredService<IOptions<SimulatorOptions>>().Value;
    app.Logger.LogInformation(
        "Simulator settings: seed={Seed} success={Success}% busy={Busy}% serverError={ServerError}% " +
        "saveThenError={SaveThenError}% lateResponse={LateResponse}% lateDelay={LateDelay}s " +
        "retryAfter={RetryMin}-{RetryMax}s format={RetryFormat}",
        o.Seed, o.Rates.Success, o.Rates.Busy, o.Rates.ServerError, o.Rates.SaveThenError, o.Rates.LateResponse,
        o.LateResponseDelaySeconds, o.RetryAfterMinSeconds, o.RetryAfterMaxSeconds, o.RetryAfterFormat);
}

public partial class Program;
