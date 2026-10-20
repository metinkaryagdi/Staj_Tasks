using InvoiceService.Api.Invoices;
using InvoiceService.Api.Reconciliation;
using InvoiceService.Api.Startup;
using InvoiceService.Api.Webhooks;
using InvoiceService.Api.Workers;
using InvoiceService.Application;
using InvoiceService.Application.Metrics;
using InvoiceService.Application.Tracing;
using InvoiceService.Infrastructure;
using Npgsql;
using OpenTelemetry.Metrics;
using OpenTelemetry.Resources;
using OpenTelemetry.Trace;

var builder = WebApplication.CreateBuilder(args);

builder.AddConsoleLogging();

builder.Services.AddInvoiceApplication(builder.Configuration);
builder.Services.AddInvoiceInfrastructure(builder.Configuration);
builder.Services.AddHostedService<OutboxWorker>();
builder.Services.AddHostedService<ReconciliationWorker>();
builder.Services.AddHostedService<DatabaseMetricsWorker>();
builder.Services.AddOpenTelemetry()
    .ConfigureResource(resource => resource.AddService("invoice-service"))
    .WithMetrics(metrics => metrics
    .AddMeter(InvoiceMetrics.MeterName)
    // Metrics go to their own Collector (OTEL_EXPORTER_OTLP_METRICS_ENDPOINT), so the trace load cannot block them.
    // AddOtlpExporter reads only OTEL_EXPORTER_OTLP_ENDPOINT (the trace Collector), the metrics address is set here.
    .AddOtlpExporter(otlp =>
    {
        if (builder.Configuration["OTEL_EXPORTER_OTLP_METRICS_ENDPOINT"] is { } endpoint)
            otlp.Endpoint = new Uri(endpoint);
    }))
    // Every recorded trace is sent; the Collector decides which are kept (tail sampling). HTTP requests, HttpClient
    // calls and database commands are traced automatically. A background worker's query is not recorded at all.
    .WithTracing(tracing => tracing
    .SetSampler(new ParentBasedSampler(new BackgroundQuerySampler()))
    .AddSource(InvoiceTracing.SourceName)
    .AddAspNetCoreInstrumentation()
    .AddHttpClientInstrumentation()
    .AddNpgsql()
    .AddOtlpExporter());

builder.Services.AddOperationsUiCors(builder.Configuration);
builder.Services.AddProblemDetails();
builder.Services.AddInvoiceOpenApi();

var app = builder.Build();

await app.MigrateDatabaseAsync();
app.LogErpSettings();
// Once the app has started OpenTelemetry listens: only then are the counters' 0s recorded, so they are exported at 0 before
// anything is counted.
app.Lifetime.ApplicationStarted.Register(() => app.Services.GetRequiredService<InvoiceMetrics>().StartAtZero());

app.UseCors(CorsExtensions.PolicyName);
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
app.MapWebhookEndpoints();
app.MapReconciliationEndpoints();

app.Run();

public partial class Program;
