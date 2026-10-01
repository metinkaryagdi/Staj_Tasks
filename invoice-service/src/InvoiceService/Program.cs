using System.Text.Json.Nodes;
using InvoiceService.Data;
using InvoiceService.Erp;
using InvoiceService.Invoices;
using InvoiceService.Outbox;
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

builder.Services.AddOptions<ErpOptions>()
    .Bind(builder.Configuration.GetSection(ErpOptions.SectionName))
    .ValidateOnStart();
builder.Services.AddSingleton<IValidateOptions<ErpOptions>, ErpOptionsValidator>();
builder.Services.AddOptions<OutboxOptions>()
    .Bind(builder.Configuration.GetSection(OutboxOptions.SectionName))
    .ValidateOnStart();
builder.Services.AddSingleton<IValidateOptions<OutboxOptions>, OutboxOptionsValidator>();

// Plain typed client on purpose: no resilience/retry handler is added, so every send hits the ERP exactly once.
builder.Services.AddHttpClient<ErpClient>((sp, http) =>
{
    var erp = sp.GetRequiredService<IOptions<ErpOptions>>().Value;
    http.BaseAddress = new Uri(erp.BaseUrl);
    http.Timeout = TimeSpan.FromSeconds(erp.TimeoutSeconds);
});

builder.Services.AddSingleton(TimeProvider.System);
builder.Services.AddSingleton(sp => new RetryPolicy(sp.GetRequiredService<IOptions<OutboxOptions>>().Value));
builder.Services.AddScoped<OutboxProcessor>();
builder.Services.AddHostedService<OutboxWorker>();

builder.Services.AddDbContext<InvoiceDbContext>(o =>
    o.UseNpgsql(builder.Configuration.GetConnectionString("InvoiceDb")));

builder.Services.AddProblemDetails();
builder.Services.AddOpenApi(o => o.AddDocumentTransformer((doc, context, _) =>
{
    var outbox = context.ApplicationServices.GetRequiredService<IOptions<OutboxOptions>>().Value;
    doc.Info.Title = "Invoice Service";
    doc.Info.Description =
        "Saves the invoice as Bekliyor and queues it in erp_outbox in the same transaction (202); " +
        "a background worker sends it to the ERP simulator, retrying 429 after Retry-After and 500/timeout/unreachable " +
        $"with exponential backoff (max {outbox.MaxBackoffSeconds}s, with jitter), at most {outbox.MaxAttempts} attempts.";
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
                ["customerCode"] = "C-001",
                ["amount"] = 1250.50m,
                ["currency"] = "TRY",
                ["invoiceDate"] = "2026-09-30"
            }
        ];
    }
    return Task.CompletedTask;
}));

var app = builder.Build();

await MigrateDatabase(app);
LogErpSettings(app);

app.UseExceptionHandler();
app.UseStatusCodePages();

app.MapOpenApi();
app.UseSwaggerUI(o =>
{
    o.SwaggerEndpoint("/openapi/v1.json", "Invoice Service v1");
    o.DocumentTitle = "Invoice Service";
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
            var db = scope.ServiceProvider.GetRequiredService<InvoiceDbContext>();
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

static void LogErpSettings(WebApplication app)
{
    var erp = app.Services.GetRequiredService<IOptions<ErpOptions>>().Value;
    var outbox = app.Services.GetRequiredService<IOptions<OutboxOptions>>().Value;
    app.Logger.LogInformation(
        "ERP settings: baseUrl={BaseUrl} timeout={Timeout}s maxConcurrentSends={Max} maxAttempts={MaxAttempts} " +
        "backoff=2^n s (max {MaxBackoff}s with jitter up to {MaxJitter}ms, margin {Margin}ms) 429=Retry-After lock={Lock}s idleDelay={Idle}ms",
        erp.BaseUrl, erp.TimeoutSeconds, outbox.MaxConcurrentSends, outbox.MaxAttempts, outbox.MaxBackoffSeconds,
        outbox.MaxJitterMilliseconds, outbox.BackoffMarginMilliseconds, outbox.LockSeconds, outbox.IdleDelayMilliseconds);
}

public partial class Program;
