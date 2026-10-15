using ErpSimulator.Api.Invoices;
using ErpSimulator.Api.Startup;
using ErpSimulator.Api.Workers;
using ErpSimulator.Application;
using ErpSimulator.Application.Simulation;
using ErpSimulator.Application.Webhooks;
using ErpSimulator.Infrastructure;
using Npgsql;
using OpenTelemetry.Metrics;
using OpenTelemetry.Resources;
using OpenTelemetry.Trace;

var builder = WebApplication.CreateBuilder(args);

builder.AddConsoleLogging();

builder.Services.AddSimulatorApplication(builder.Configuration);
builder.Services.AddSimulatorInfrastructure(builder.Configuration);
builder.Services.AddHostedService<WebhookDispatcher>();
builder.Services.AddHostedService<RateLimitRefiller>();
builder.Services.AddOpenTelemetry()
    .ConfigureResource(resource => resource.AddService("erp-simulator"))
    .WithMetrics(metrics => metrics
    .AddMeter(SimulatorMetrics.MeterName)
    .AddOtlpExporter())
    // Every trace is sent; the Collector decides which are kept (tail sampling). HTTP requests, HttpClient calls and
    // database commands are traced automatically.
    .WithTracing(tracing => tracing
    .SetSampler(new AlwaysOnSampler())
    .AddSource(SimulatorTracing.SourceName)
    .AddAspNetCoreInstrumentation()
    .AddHttpClientInstrumentation()
    .AddNpgsql()
    .AddOtlpExporter());

builder.Services.AddProblemDetails();
builder.Services.AddSimulatorOpenApi();

var app = builder.Build();

await app.MigrateDatabaseAsync();
app.LogSimulatorSettings();
// Once the app has started OpenTelemetry listens: only then are the counters' 0s recorded, so they are exported at 0 before
// anything is counted.
app.Lifetime.ApplicationStarted.Register(() => app.Services.GetRequiredService<SimulatorMetrics>().StartAtZero());

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

public partial class Program;
