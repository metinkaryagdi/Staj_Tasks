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

    /// <summary>Keep the invoices answered 202: GET finds them and a cancellation is accepted once (a repeated one gets the
    /// same reference); an unknown invoice's cancellation gets 404. Off by default: GET always answers 404.</summary>
    public bool KeepRecords { get; set; }

    /// <summary>How many cancellation records the fake ERP holds.</summary>
    public int CancellationCount { get { lock (_lock) return _cancelled.Count; } }

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
        app.MapPost("api/v1/invoices", (PostedInvoice body) => erp!.Post(body.InvoiceNumber));
        app.MapGet("api/v1/invoices/{number}", (string number) => erp!.Get(number));
        app.MapPost("api/v1/invoices/{number}/cancel", (string number) => erp!.Cancel(number));

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
            if (!KeepRecords || !_accepted.Contains(number))
                return Results.NotFound();
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

    private sealed record PostedInvoice(string InvoiceNumber);
}
