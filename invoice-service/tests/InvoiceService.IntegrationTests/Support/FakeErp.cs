using Microsoft.AspNetCore.Builder;
using Microsoft.AspNetCore.Hosting;
using Microsoft.AspNetCore.Hosting.Server;
using Microsoft.AspNetCore.Hosting.Server.Features;
using Microsoft.AspNetCore.Http;
using Microsoft.Extensions.DependencyInjection;
using Microsoft.Extensions.Logging;

namespace InvoiceService.IntegrationTests.Support;

/// <summary>
/// A small HTTP server inside the test that answers like the ERP: POST api/v1/invoices and GET api/v1/invoices/{number}.
/// It accepts every invoice and has no record of any; a test can make it refuse invoices.
/// </summary>
public sealed class FakeErp : IAsyncDisposable
{
    private readonly WebApplication _app;

    /// <summary>The answer to POST api/v1/invoices, by invoice number.</summary>
    public Func<string, IResult> OnPost { get; set; } = number => Results.Json(new { erpReference = $"ERP-{number}" }, statusCode: 202);

    /// <summary>From now on every invoice is refused with 400, which the service treats as final: the invoice is
    /// Başarısız at once.</summary>
    public void RefuseInvoices() => OnPost = _ => Results.Problem(statusCode: 400, title: "reddedildi");

    /// <summary>From now on every invoice is accepted again.</summary>
    public void AcceptInvoices() => OnPost = number => Results.Json(new { erpReference = $"ERP-{number}" }, statusCode: 202);

    public string BaseUrl { get; }

    private FakeErp(WebApplication app, string baseUrl)
    {
        _app = app;
        BaseUrl = baseUrl;
    }

    public static async Task<FakeErp> StartAsync()
    {
        var builder = WebApplication.CreateBuilder();
        builder.Logging.ClearProviders();
        builder.WebHost.UseUrls("http://127.0.0.1:0");
        var app = builder.Build();

        FakeErp? erp = null;
        app.MapPost("api/v1/invoices", (PostedInvoice body) => erp!.OnPost(body.InvoiceNumber));
        app.MapGet("api/v1/invoices/{number}", () => Results.NotFound());

        await app.StartAsync();
        var address = app.Services.GetRequiredService<IServer>().Features.Get<IServerAddressesFeature>()!.Addresses.First();
        erp = new FakeErp(app, address);
        return erp;
    }

    public async ValueTask DisposeAsync() => await _app.DisposeAsync();

    private sealed record PostedInvoice(string InvoiceNumber);
}
