using InvoiceService.Api.Invoices;
using InvoiceService.Api.Startup;
using InvoiceService.Api.Webhooks;
using InvoiceService.Api.Workers;
using InvoiceService.Application;
using InvoiceService.Infrastructure;

var builder = WebApplication.CreateBuilder(args);

builder.AddConsoleLogging();

builder.Services.AddInvoiceApplication(builder.Configuration);
builder.Services.AddInvoiceInfrastructure(builder.Configuration);
builder.Services.AddHostedService<OutboxWorker>();

builder.Services.AddProblemDetails();
builder.Services.AddInvoiceOpenApi();

var app = builder.Build();

await app.MigrateDatabaseAsync();
app.LogErpSettings();

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

app.Run();

public partial class Program;
