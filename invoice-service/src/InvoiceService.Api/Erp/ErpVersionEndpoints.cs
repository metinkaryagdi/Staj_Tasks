using InvoiceService.Api.Auth;
using InvoiceService.Application.Abstractions;

namespace InvoiceService.Api.Erp;

public static class ErpVersionEndpoints
{
    public static IEndpointRouteBuilder MapErpVersionEndpoints(this IEndpointRouteBuilder app)
    {
        var group = app.MapGroup("/api/v1/erp-version").WithTags("ERP version");

        group.MapGet("/", async (IErpVersionSetting setting, CancellationToken ct) =>
                Results.Ok(new ErpVersionShare(await setting.GetV2PercentAsync(ct))))
            .WithName("GetErpVersionShare")
            .WithSummary("The share of invoices that use the ERP's new API")
            .Produces<ErpVersionShare>()
            .RequireAuthorization(Policies.Read);

        group.MapPut("/", SetShare)
            .WithName("SetErpVersionShare")
            .WithSummary("Change the share of invoices that use the ERP's new API, without a restart")
            .WithDescription(
                "0: every request uses v1 (the way back). 100: every request uses v2. Between: an invoice number always falls on the " +
                "same side, and raising the share only moves invoices to v2. Every copy uses the new value from its next request.")
            .Produces<ErpVersionShare>()
            .ProducesValidationProblem()
            .RequireAuthorization(Policies.Intervene);

        return app;
    }

    private static async Task<IResult> SetShare(
        ErpVersionShare body, IErpVersionSetting setting, ILoggerFactory loggerFactory, CancellationToken ct)
    {
        if (body.V2Percent is < 0 or > 100)
        {
            return Results.ValidationProblem(new Dictionary<string, string[]>
            {
                [nameof(body.V2Percent)] = ["Must be between 0 and 100."]
            });
        }

        await setting.SetV2PercentAsync(body.V2Percent, ct);
        loggerFactory.CreateLogger("InvoiceService.ErpVersion").LogInformation("ERP v2 share set to {V2Percent}%", body.V2Percent);
        return Results.Ok(body);
    }
}

public sealed record ErpVersionShare(int V2Percent);
