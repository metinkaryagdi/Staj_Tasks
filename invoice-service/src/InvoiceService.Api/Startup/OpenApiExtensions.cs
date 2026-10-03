using System.Text.Json.Nodes;
using InvoiceService.Application.Invoices;
using InvoiceService.Application.Outbox;

namespace InvoiceService.Api.Startup;

public static class OpenApiExtensions
{
    public static IServiceCollection AddInvoiceOpenApi(this IServiceCollection services) =>
        services.AddOpenApi(o => o.AddDocumentTransformer((doc, context, _) =>
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
}
