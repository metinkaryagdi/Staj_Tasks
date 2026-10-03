using System.Text.Json.Nodes;
using ErpSimulator.Application.Invoices;

namespace ErpSimulator.Api.Startup;

public static class OpenApiExtensions
{
    public static IServiceCollection AddSimulatorOpenApi(this IServiceCollection services) =>
        services.AddOpenApi(o => o.AddDocumentTransformer((doc, _, _) =>
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
}
