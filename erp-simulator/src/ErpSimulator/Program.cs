using System.Text.Json.Nodes;
using ErpSimulator.Data;
using ErpSimulator.Invoices;
using ErpSimulator.Simulation;
using ErpSimulator.Webhooks;
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

builder.Services.AddOptions<WebhookOptions>()
    .Bind(builder.Configuration.GetSection(WebhookOptions.SectionName))
    .ValidateOnStart();
builder.Services.AddSingleton<IValidateOptions<WebhookOptions>, WebhookOptionsValidator>();
builder.Services.AddSingleton(TimeProvider.System);
builder.Services.AddSingleton<WebhookPlanner>();
// The 5 s limit is applied per send by the dispatcher (its own token), so the client itself never cuts a send short.
builder.Services.AddHttpClient(WebhookDispatcher.HttpClientName, http => http.Timeout = Timeout.InfiniteTimeSpan);
builder.Services.AddHostedService<WebhookDispatcher>();

builder.Services.AddDbContext<ErpDbContext>(o =>
    o.UseNpgsql(builder.Configuration.GetConnectionString("ErpDb")));

builder.Services.AddProblemDetails();
builder.Services.AddOpenApi(o => o.AddDocumentTransformer((doc, _, _) =>
{
    doc.Info.Title = "ERP Simulator";
    doc.Info.Description =
        "Fault-injecting ERP used by the invoice integration. Every POST picks a seeded random behavior " +
        "(Success / Busy / ServerError / SaveThenError / LateResponse), so repeated calls intentionally return different results.";
    return Task.CompletedTask;
}).AddSchemaTransformer((schema, context, _) =>
{
    // A valid example so Swagger's "Try it out" works without editing the body.
    if (context.JsonTypeInfo.Type == typeof(CreateInvoiceRequest))
    {
        schema.Examples =
        [
            new JsonObject
            {
                ["invoiceNumber"] = "INV-2026-0001",
                ["customerCode"] = "C-001",
                ["amount"] = 1250.50m,
                ["currency"] = "TRY",
                ["invoiceDate"] = "2026-09-29"
            }
        ];
    }
    return Task.CompletedTask;
}));

var app = builder.Build();

await MigrateDatabase(app);
LogSimulatorSettings(app);

app.UseExceptionHandler();
app.UseStatusCodePages();

// Swagger is enabled in every environment on purpose: this is a test tool, not a production service.
app.MapOpenApi();
app.UseSwaggerUI(o =>
{
    o.SwaggerEndpoint("/openapi/v1.json", "ERP Simulator v1");
    o.DocumentTitle = "ERP Simulator";
});
app.MapGet("/", () => Results.Redirect("/swagger")).ExcludeFromDescription();

app.MapGet("/health", () => Results.Ok(new { status = "ok" })).ExcludeFromDescription();
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
    var r = o.Rates;
    string Pct(double rate) => rate.ToString(System.Globalization.CultureInfo.InvariantCulture);

    app.Logger.LogInformation(
        "Simulator settings: seed={Seed} success={Success}% busy={Busy}% serverError={ServerError}% " +
        "saveThenError={SaveThenError}% lateResponse={LateResponse}% (total={Total}) lateDelay={LateDelay}s " +
        "retryAfter={RetryMin}-{RetryMax}s format={RetryFormat} idempotentInvoices={IdempotentInvoices}",
        o.Seed, Pct(r.Success), Pct(r.Busy), Pct(r.ServerError), Pct(r.SaveThenError), Pct(r.LateResponse), r.Total,
        o.LateResponseDelaySeconds, o.RetryAfterMinSeconds, o.RetryAfterMaxSeconds, o.RetryAfterFormat,
        o.IdempotentInvoices);

    // The secret itself is never logged.
    var w = app.Services.GetRequiredService<IOptions<WebhookOptions>>().Value;
    app.Logger.LogInformation(
        "Webhook settings: enabled={Enabled} target={Target} timeout={Timeout}s retries={Retries}s first={FirstMin}-{FirstMax}s " +
        "second={SecondMin}-{SecondMax}s approval={Approval}% maxConcurrent={Max}",
        w.Enabled, w.TargetUrl, w.TimeoutSeconds, string.Join(",", w.RetryDelaysSeconds), w.FirstEventMinSeconds, w.FirstEventMaxSeconds,
        w.SecondEventMinSeconds, w.SecondEventMaxSeconds, Pct(w.ApprovalRate), w.MaxConcurrentSends);
}

public partial class Program;
