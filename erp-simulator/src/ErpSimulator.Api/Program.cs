using ErpSimulator.Api.Invoices;
using ErpSimulator.Api.Startup;
using ErpSimulator.Api.Workers;
using ErpSimulator.Application;
using ErpSimulator.Infrastructure;

var builder = WebApplication.CreateBuilder(args);

builder.AddConsoleLogging();

builder.Services.AddSimulatorApplication(builder.Configuration);
builder.Services.AddSimulatorInfrastructure(builder.Configuration);
builder.Services.AddHostedService<WebhookDispatcher>();
builder.Services.AddHostedService<RateLimitRefiller>();

builder.Services.AddProblemDetails();
builder.Services.AddSimulatorOpenApi();

var app = builder.Build();

await app.MigrateDatabaseAsync();
app.LogSimulatorSettings();

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
