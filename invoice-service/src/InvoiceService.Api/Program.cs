using InvoiceService.Api.Invoices;
using InvoiceService.Api.Reconciliation;
using InvoiceService.Api.Startup;
using InvoiceService.Api.Webhooks;
using InvoiceService.Api.Workers;
using InvoiceService.Application;
using InvoiceService.Application.Metrics;
using InvoiceService.Infrastructure;
using OpenTelemetry.Metrics;
using OpenTelemetry.Resources;

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
    .AddPrometheusExporter());

builder.Services.AddOperationsUiCors(builder.Configuration);
builder.Services.AddProblemDetails();
builder.Services.AddInvoiceOpenApi();

var app = builder.Build();

await app.MigrateDatabaseAsync();
app.LogErpSettings();
// Once the app has started OpenTelemetry listens: only then are the counters' 0s recorded, so they are scraped at 0 before
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
app.MapPrometheusScrapingEndpoint();
app.MapInvoiceEndpoints();
app.MapWebhookEndpoints();
app.MapReconciliationEndpoints();

app.Run();

public partial class Program;
