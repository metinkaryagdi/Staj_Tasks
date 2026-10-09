using System.Collections.Concurrent;
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
/// By default it accepts every invoice and has no record of any; a test changes the answers it needs.
/// </summary>
public sealed class FakeErp : IAsyncDisposable
{
    private readonly WebApplication _app;
    private readonly ConcurrentQueue<string> _posted = new();

    /// <summary>The answer to POST api/v1/invoices, by invoice number.</summary>
    public Func<string, IResult> OnPost { get; set; } = number => Results.Json(new { erpReference = $"ERP-{number}" }, statusCode: 202);

    /// <summary>The answer to GET api/v1/invoices/{number}.</summary>
    public Func<string, IResult> OnGet { get; set; } = _ => Results.NotFound();

    public string BaseUrl { get; }

    /// <summary>The invoice numbers posted so far, in the order they arrived.</summary>
    public IReadOnlyCollection<string> Posted => _posted;

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
        app.MapPost("api/v1/invoices", (PostedInvoice body) =>
        {
            erp!._posted.Enqueue(body.InvoiceNumber);
            return erp.OnPost(body.InvoiceNumber);
        });
        app.MapGet("api/v1/invoices/{number}", (string number) => erp!.OnGet(number));

        await app.StartAsync();
        var address = app.Services.GetRequiredService<IServer>().Features.Get<IServerAddressesFeature>()!.Addresses.First();
        erp = new FakeErp(app, address);
        return erp;
    }

    public async ValueTask DisposeAsync() => await _app.DisposeAsync();

    private sealed record PostedInvoice(string InvoiceNumber);
}
