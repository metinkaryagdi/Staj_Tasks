using System.Net;
using System.Text;
using InvoiceService.Data;
using InvoiceService.Erp;

namespace InvoiceService.Tests;

public class ErpClientTests
{
    private static Invoice SampleInvoice() => new()
    {
        InvoiceNumber = "FTR-000001",
        CustomerCode = "C-001",
        Amount = 1250.50m,
        Currency = "TRY",
        InvoiceDate = new DateOnly(2026, 9, 30),
        Status = InvoiceStatus.Failed
    };

    private sealed class StubHandler(Func<HttpRequestMessage, CancellationToken, Task<HttpResponseMessage>> respond)
        : HttpMessageHandler
    {
        public int Calls { get; private set; }
        public string? LastBody { get; private set; }

        protected override async Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken ct)
        {
            Calls++;
            LastBody = request.Content is null ? null : await request.Content.ReadAsStringAsync(ct);
            return await respond(request, ct);
        }
    }

    private static (ErpClient Client, StubHandler Handler) Create(
        Func<HttpRequestMessage, CancellationToken, Task<HttpResponseMessage>> respond, TimeSpan? timeout = null)
    {
        var handler = new StubHandler(respond);
        var http = new HttpClient(handler)
        {
            BaseAddress = new Uri("http://erp.test/"),
            Timeout = timeout ?? TimeSpan.FromSeconds(10)
        };
        return (new ErpClient(http), handler);
    }

    private static Task<HttpResponseMessage> Reply(HttpStatusCode status, string body, string mediaType = "application/json")
    {
        var response = new HttpResponseMessage(status) { Content = new StringContent(body, Encoding.UTF8, mediaType) };
        return Task.FromResult(response);
    }

    [Fact]
    public async Task Accepted_with_reference_is_sent()
    {
        var (client, handler) = Create((_, _) => Reply(HttpStatusCode.Accepted,
            """{"erpReference":"ERP-00000042","invoiceNumber":"FTR-000001","receivedAt":"2026-09-30T07:00:00+00:00"}"""));

        var result = await client.SendAsync(SampleInvoice(), CancellationToken.None);

        Assert.True(result.Accepted);
        Assert.Equal("ERP-00000042", result.ErpReference);
        Assert.Null(result.Error);
        Assert.Equal(1, handler.Calls);
        Assert.Contains("\"invoiceNumber\":\"FTR-000001\"", handler.LastBody);
        Assert.Contains("\"invoiceDate\":\"2026-09-30\"", handler.LastBody);
    }

    [Fact]
    public async Task Busy_is_failed_once_and_passes_retry_after_on()
    {
        var (client, handler) = Create((_, _) =>
        {
            var response = new HttpResponseMessage(HttpStatusCode.TooManyRequests)
            {
                Content = new StringContent("""{"title":"ERP is busy","status":429,"detail":"Try again in 5 seconds."}""",
                    Encoding.UTF8, "application/problem+json")
            };
            response.Headers.Add("Retry-After", "5");
            return Task.FromResult(response);
        });

        var result = await client.SendAsync(SampleInvoice(), CancellationToken.None);

        Assert.False(result.Accepted);
        Assert.Null(result.ErpReference);
        Assert.Equal(429, result.HttpStatus);
        Assert.Contains("429", result.Error);
        Assert.Contains("ERP is busy", result.Error);
        Assert.Equal(TimeSpan.FromSeconds(5), result.RetryAfter?.Delta);
        Assert.Equal(1, handler.Calls);
    }

    [Fact]
    public async Task Retry_after_as_http_date_is_passed_on()
    {
        var (client, _) = Create((_, _) =>
        {
            var response = new HttpResponseMessage(HttpStatusCode.TooManyRequests) { Content = new StringContent("") };
            response.Headers.Add("Retry-After", "Thu, 01 Oct 2026 07:00:17 GMT");
            return Task.FromResult(response);
        });

        var result = await client.SendAsync(SampleInvoice(), CancellationToken.None);

        Assert.Equal(new DateTimeOffset(2026, 10, 1, 7, 0, 17, TimeSpan.Zero), result.RetryAfter?.Date);
    }

    [Theory]
    [InlineData(HttpStatusCode.InternalServerError)]
    [InlineData(HttpStatusCode.OK)]
    [InlineData(HttpStatusCode.Created)]
    [InlineData(HttpStatusCode.BadRequest)]
    public async Task Anything_other_than_202_is_failed(HttpStatusCode status)
    {
        var (client, _) = Create((_, _) => Reply(status, """{"erpReference":"ERP-00000001","title":"x"}"""));

        var result = await client.SendAsync(SampleInvoice(), CancellationToken.None);

        Assert.False(result.Accepted);
        Assert.Null(result.ErpReference);
        Assert.Equal((int)status, result.HttpStatus);
    }

    [Fact]
    public async Task Accepted_without_reference_is_failed()
    {
        var (client, _) = Create((_, _) => Reply(HttpStatusCode.Accepted, "{}"));

        var result = await client.SendAsync(SampleInvoice(), CancellationToken.None);

        Assert.False(result.Accepted);
        Assert.Contains("erpReference yok", result.Error);
    }

    [Fact]
    public async Task Timeout_is_failed_with_timeout_error()
    {
        var (client, handler) = Create(async (_, ct) =>
        {
            await Task.Delay(TimeSpan.FromSeconds(30), ct);
            return new HttpResponseMessage(HttpStatusCode.Accepted);
        }, timeout: TimeSpan.FromMilliseconds(200));

        var result = await client.SendAsync(SampleInvoice(), CancellationToken.None);

        Assert.False(result.Accepted);
        Assert.Null(result.HttpStatus);
        Assert.Contains("zaman aşımı", result.Error);
        Assert.True(result.Elapsed < TimeSpan.FromSeconds(5));
        Assert.Equal(1, handler.Calls);
    }

    [Fact]
    public async Task Unreachable_erp_is_failed_with_connection_error()
    {
        var (client, _) = Create((_, _) => throw new HttpRequestException("Connection refused (erp-simulator:8080)"));

        var result = await client.SendAsync(SampleInvoice(), CancellationToken.None);

        Assert.False(result.Accepted);
        Assert.Null(result.HttpStatus);
        Assert.Contains("ulaşılamadı", result.Error);
        Assert.Contains("Connection refused", result.Error);
    }

    [Fact]
    public async Task Non_json_error_body_is_kept_shortened()
    {
        var (client, _) = Create((_, _) => Reply(HttpStatusCode.BadGateway, new string('x', 2000), "text/plain"));

        var result = await client.SendAsync(SampleInvoice(), CancellationToken.None);

        Assert.False(result.Accepted);
        Assert.True(result.Error!.Length < 700);
    }

    [Fact]
    public async Task Lookup_200_with_reference_is_found()
    {
        var (client, handler) = Create((request, _) =>
        {
            Assert.Equal(HttpMethod.Get, request.Method);
            Assert.Equal("/api/v1/invoices/FTR-000001", request.RequestUri!.AbsolutePath);
            return Reply(HttpStatusCode.OK,
                """{"invoiceNumber":"FTR-000001","registered":true,"erpReference":"ERP-00000007","recordCount":1,"records":[]}""");
        });

        var result = await client.FindAsync("FTR-000001", CancellationToken.None);

        Assert.Equal(ErpLookup.Found, result.Lookup);
        Assert.Equal("ERP-00000007", result.ErpReference);
        Assert.Equal(1, handler.Calls);
    }

    [Fact]
    public async Task Lookup_404_is_not_found()
    {
        var (client, _) = Create((_, _) => Reply(HttpStatusCode.NotFound, """{"title":"Invoice not found"}"""));

        var result = await client.FindAsync("FTR-000001", CancellationToken.None);

        Assert.Equal(ErpLookup.NotFound, result.Lookup);
        Assert.Null(result.Error);
    }

    [Theory]
    [InlineData(HttpStatusCode.InternalServerError, """{"title":"boom"}""")]
    [InlineData(HttpStatusCode.OK, "not json")]
    [InlineData(HttpStatusCode.OK, """{"registered":true}""")]
    [InlineData(HttpStatusCode.BadRequest, """{"title":"bad"}""")]
    public async Task Lookup_without_a_clear_answer_is_unknown(HttpStatusCode status, string body)
    {
        var (client, _) = Create((_, _) => Reply(status, body));

        var result = await client.FindAsync("FTR-000001", CancellationToken.None);

        Assert.Equal(ErpLookup.Unknown, result.Lookup);
        Assert.Contains("sorulamadı", result.Error);
    }

    [Fact]
    public async Task Lookup_timeout_and_unreachable_are_unknown()
    {
        var (slow, _) = Create(async (_, ct) =>
        {
            await Task.Delay(TimeSpan.FromSeconds(5), ct);
            return new HttpResponseMessage(HttpStatusCode.OK);
        }, TimeSpan.FromMilliseconds(100));
        var (down, _) = Create((_, _) => throw new HttpRequestException("Connection refused"));

        Assert.Equal(ErpLookup.Unknown, (await slow.FindAsync("FTR-000001", CancellationToken.None)).Lookup);
        Assert.Equal(ErpLookup.Unknown, (await down.FindAsync("FTR-000001", CancellationToken.None)).Lookup);
    }
}
