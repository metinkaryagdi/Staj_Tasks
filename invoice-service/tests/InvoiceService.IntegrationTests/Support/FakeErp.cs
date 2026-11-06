using Microsoft.AspNetCore.Builder;
using Microsoft.AspNetCore.Hosting;
using Microsoft.AspNetCore.Hosting.Server;
using Microsoft.AspNetCore.Hosting.Server.Features;
using Microsoft.AspNetCore.Http;
using Microsoft.Extensions.DependencyInjection;
using Microsoft.Extensions.Logging;

namespace InvoiceService.IntegrationTests.Support;

/// <summary>
/// A small HTTP server inside the test that answers like the ERP: POST api/v1/invoices, GET api/v1/invoices/{number} and
/// POST api/v1/invoices/{number}/cancel. It accepts every invoice and has no record of any; a test can make it refuse
/// invoices, or keep the invoices it accepted (<see cref="KeepRecords"/>) so it answers GET and cancellations like the ERP.
/// </summary>
public sealed class FakeErp : IAsyncDisposable
{
    private readonly WebApplication _app;
    private readonly Lock _lock = new();
    private readonly HashSet<string> _accepted = [];
    private readonly Dictionary<string, string> _cancelled = [];

    /// <summary>Every request in the order it arrived, e.g. "POST FTR-000001", "CANCEL FTR-000001".</summary>
    public List<string> Requests { get; } = [];

    /// <summary>The path of every request to the ERP, in the order they arrived; 410s included.</summary>
    public List<string> Paths { get; } = [];

    /// <summary>The kuruş amount of each v2 POST, by invoice number.</summary>
    public Dictionary<string, long> KurusPosted { get; } = [];

    /// <summary>Every /api/v1 request gets 410, as the ERP answers when the version is closed.</summary>
    public bool V1Closed { get; set; }

    /// <summary>Keep the invoices answered 202: GET finds them and a cancellation is accepted once (a repeated one gets the
    /// same reference); an unknown invoice's cancellation gets 404. Off by default: GET always answers 404.</summary>
    public bool KeepRecords { get; set; }

    /// <summary>How many cancellation records the fake ERP holds.</summary>
    public int CancellationCount { get { lock (_lock) return _cancelled.Count; } }

    /// <summary>When set, the answer to GET api/v1/invoices/{number}; every question is listed in
    /// <see cref="Lookups"/>.</summary>
    public Func<string, IResult>? OnGet { get; set; }

    /// <summary>The invoice numbers asked with <see cref="OnGet"/> set, in the order they were asked.</summary>
    public List<string> Lookups { get; } = [];

    /// <summary>The answer to POST api/v1/invoices, by invoice number.</summary>
    public Func<string, IResult> OnPost { get; set; } = number => Results.Json(new { erpReference = $"ERP-{number}" }, statusCode: 202);

    /// <summary>From now on every invoice is refused with 400, which the service treats as final: the invoice is
    /// Başarısız at once.</summary>
    public void RefuseInvoices() => OnPost = _ => Results.Problem(statusCode: 400, title: "reddedildi");

    /// <summary>The ERP has this invoice from now on, however its answer ended (with <see cref="KeepRecords"/>).</summary>
    public void RecordInvoice(string number)
    {
        lock (_lock) _accepted.Add(number);
    }

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
        app.Use(async (context, next) =>
        {
            var path = context.Request.Path.Value!;
            lock (erp!._lock) erp.Paths.Add(path);
            if (erp.V1Closed && path.StartsWith("/api/v1"))
                await Results.Problem(statusCode: 410, title: "API version closed").ExecuteAsync(context);
            else
                await next();
        });
        app.MapPost("api/v1/invoices", (PostedInvoice body) => erp!.Post(body.InvoiceNumber));
        app.MapPost("api/v2/invoices", (PostedInvoice body) =>
        {
            lock (erp!._lock) erp.KurusPosted[body.InvoiceNumber] = body.AmountKurus ?? 0;
            return erp.Post(body.InvoiceNumber);
        });
        foreach (var version in new[] { "v1", "v2" })
        {
            app.MapGet($"api/{version}/invoices", () => Results.Ok(new { totalCount = 0, items = Array.Empty<object>() }));
            app.MapGet($"api/{version}/invoices/{{number}}", (string number) => erp!.Get(number));
            app.MapPost($"api/{version}/invoices/{{number}}/cancel", (string number) => erp!.Cancel(number));
        }

        await app.StartAsync();
        var address = app.Services.GetRequiredService<IServer>().Features.Get<IServerAddressesFeature>()!.Addresses.First();
        erp = new FakeErp(app, address);
        return erp;
    }

    public async ValueTask DisposeAsync() => await _app.DisposeAsync();

    private IResult Post(string number)
    {
        lock (_lock) Requests.Add($"POST {number}");
        var answer = OnPost(number);
        if (KeepRecords && answer is IStatusCodeHttpResult { StatusCode: 202 })
            lock (_lock) _accepted.Add(number);
        return answer;
    }

    private IResult Get(string number)
    {
        lock (_lock)
        {
            if (OnGet is not null)
            {
                Lookups.Add(number);
                return OnGet(number);
            }
            if (!KeepRecords || !_accepted.Contains(number))
                return Results.Problem(statusCode: 404, title: "Invoice not found");
            return Results.Ok(new { erpReference = $"ERP-{number}", cancelReference = _cancelled.GetValueOrDefault(number) });
        }
    }

    private IResult Cancel(string number)
    {
        lock (_lock)
        {
            Requests.Add($"CANCEL {number}");
            if (!_accepted.Contains(number))
                return Results.Problem(statusCode: 404, title: "Invoice not found");
            if (!_cancelled.TryGetValue(number, out var reference))
                _cancelled[number] = reference = $"IPT-{number}";
            return Results.Json(new { cancelReference = reference, invoiceNumber = number }, statusCode: 202);
        }
    }

    private sealed record PostedInvoice(string InvoiceNumber, long? AmountKurus);
}
