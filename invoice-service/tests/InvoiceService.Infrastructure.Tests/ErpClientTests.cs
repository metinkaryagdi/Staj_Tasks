using System.Net;
using System.Text;
using InvoiceService.Application.Abstractions;
using InvoiceService.Domain.Invoices;
using InvoiceService.Infrastructure.Erp;

namespace InvoiceService.Infrastructure.Tests;

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

    [Theory]
    [InlineData("[]")]
    [InlineData("null")]
    [InlineData("42")]
    [InlineData("\"ERP-00000001\"")]
    public async Task Accepted_with_a_body_that_is_not_an_object_is_failed_not_thrown(string body)
    {
        var (client, _) = Create((_, _) => Reply(HttpStatusCode.Accepted, body));

        var result = await client.SendAsync(SampleInvoice(), CancellationToken.None);

        Assert.False(result.Accepted);
        Assert.Contains("erpReference yok", result.Error);
    }

    [Theory]
    [InlineData("[]")]
    [InlineData("null")]
    [InlineData("42")]
    [InlineData("\"ERP-00000001\"")]
    public async Task Lookup_200_with_a_body_that_is_not_an_object_is_unknown_not_thrown(string body)
    {
        var (client, _) = Create((_, _) => Reply(HttpStatusCode.OK, body));

        var result = await client.FindAsync("FTR-000001", CancellationToken.None);

        Assert.Equal(ErpLookup.Unknown, result.Lookup);
    }

    [Theory]
    [InlineData("""{"title":42,"detail":"x"}""")]
    [InlineData("""{"title":{},"detail":"x"}""")]
    [InlineData("""{"title":["a"]}""")]
    public async Task Error_body_with_a_title_that_is_not_a_string_is_failed_not_thrown(string body)
    {
        var (client, _) = Create((_, _) => Reply(HttpStatusCode.InternalServerError, body));

        var result = await client.SendAsync(SampleInvoice(), CancellationToken.None);

        Assert.False(result.Accepted);
        Assert.Contains(body, result.Error);
    }

    [Theory]
    [InlineData("""{"title":42}""")]
    [InlineData("""{"title":{}}""")]
    public async Task Lookup_error_with_a_title_that_is_not_a_string_is_unknown_not_thrown(string body)
    {
        var (client, _) = Create((_, _) => Reply(HttpStatusCode.InternalServerError, body));

        var result = await client.FindAsync("FTR-000001", CancellationToken.None);

        Assert.Equal(ErpLookup.Unknown, result.Lookup);
    }

    // --- Karar ve liste (mutabakat)
    // ------------------------------------------------------------------------------------

    [Fact]
    public async Task A_lookup_returns_the_erps_decision()
    {
        var (client, _) = Create((_, _) => Reply(HttpStatusCode.OK,
            """{"invoiceNumber":"FTR-000001","registered":true,"erpReference":"ERP-1","recordCount":1,"records":[],"decision":"rejected","reason":"Mükerrer fatura","decided_at":"2026-10-05T09:00:00+00:00"}"""));

        var result = await client.FindAsync("FTR-000001", CancellationToken.None);

        Assert.Equal(ErpLookup.Found, result.Lookup);
        Assert.Equal(ErpDecisionKind.Rejected, result.Decision!.Kind);
        Assert.Equal("Mükerrer fatura", result.Decision.Reason);
        Assert.Equal(new DateTimeOffset(2026, 10, 5, 9, 0, 0, TimeSpan.Zero), result.Decision.DecidedAt);
    }

    [Fact]
    public async Task A_lookup_without_decision_fields_has_no_decision()
    {
        var (client, _) = Create((_, _) => Reply(HttpStatusCode.OK, """{"erpReference":"ERP-1"}"""));

        var result = await client.FindAsync("FTR-000001", CancellationToken.None);

        Assert.Equal(ErpLookup.Found, result.Lookup);
        Assert.Equal(ErpDecisionKind.None, result.Decision!.Kind);
    }

    [Fact]
    public async Task A_lookup_returns_the_erps_records_of_the_number()
    {
        var (client, _) = Create((_, _) => Reply(HttpStatusCode.OK,
            """{"invoiceNumber":"FTR-000001","registered":true,"erpReference":"ERP-1","recordCount":2,"records":[{"erpReference":"ERP-1","customerCode":"C-001","amount":100.50,"currency":"TRY","invoiceDate":"2026-10-05","receivedAt":"2026-10-05T09:00:00+00:00"},{"erpReference":"ERP-2","customerCode":"C-001","amount":100.50,"currency":"TRY","invoiceDate":"2026-10-05","receivedAt":"2026-10-05T09:01:00+00:00"}],"decision":"received"}"""));

        var result = await client.FindAsync("FTR-000001", CancellationToken.None);

        Assert.Equal(["ERP-1", "ERP-2"], result.Records!.Select(r => r.ErpReference));
        Assert.All(result.Records!, r => Assert.Equal("FTR-000001", r.InvoiceNumber));
        Assert.Equal(100.50m, result.Records![0].Amount);
        Assert.Equal(new DateOnly(2026, 10, 5), result.Records![0].InvoiceDate);
    }

    [Theory]
    [InlineData("""{"erpReference":"ERP-1"}""")]
    [InlineData("""{"erpReference":"ERP-1","records":[{"erpReference":"ERP-1","amount":"many"}]}""")]
    public async Task A_lookup_whose_records_cannot_be_read_is_still_found_but_has_no_records(string body)
    {
        var (client, _) = Create((_, _) => Reply(HttpStatusCode.OK, body));

        var result = await client.FindAsync("FTR-000001", CancellationToken.None);

        Assert.Equal(ErpLookup.Found, result.Lookup);
        Assert.Null(result.Records);
    }

    private static string ListPage(int total, params string[] numbers) =>
        $$"""{"page":1,"pageSize":2,"totalCount":{{total}},"items":[{{string.Join(",", numbers.Select(n =>
            $$"""{"invoiceNumber":"{{n}}","erpReference":"ERP-{{n}}","customerCode":"C-001","amount":100.50,"currency":"TRY","invoiceDate":"2026-10-05","receivedAt":"2026-10-05T09:00:00+00:00"}"""))}}]}""";

    [Fact]
    public async Task The_list_reads_every_page_and_asks_for_the_largest_page_size()
    {
        var urls = new List<string>();
        var (client, handler) = Create((request, _) =>
        {
            urls.Add(request.RequestUri!.PathAndQuery);
            return Reply(HttpStatusCode.OK, request.RequestUri.Query.Contains("page=1") ? ListPage(3, "A", "B") : ListPage(3, "C"));
        });

        var result = await client.ListAsync(
            new DateTimeOffset(2026, 10, 4, 12, 0, 0, TimeSpan.FromHours(3)), new DateTimeOffset(2026, 10, 5, 12, 0, 0, TimeSpan.Zero),
            CancellationToken.None);

        Assert.True(result.Succeeded);
        Assert.Equal(["A", "B", "C"], result.Records.Select(r => r.InvoiceNumber));
        Assert.Equal(100.50m, result.Records[0].Amount);
        Assert.Equal(2, handler.Calls);
        Assert.All(urls, url => Assert.Contains("pageSize=500", url));
        Assert.Contains("from=2026-10-04T12%3A00%3A00.0000000%2B03%3A00", urls[0]);
    }

    [Fact]
    public async Task An_empty_range_is_a_successful_empty_list()
    {
        var (client, handler) = Create((_, _) => Reply(HttpStatusCode.OK, ListPage(0)));

        var result = await client.ListAsync(DateTimeOffset.UnixEpoch, DateTimeOffset.UtcNow, CancellationToken.None);

        Assert.True(result.Succeeded);
        Assert.Empty(result.Records);
        Assert.Equal(1, handler.Calls);
    }

    [Fact]
    public async Task An_empty_page_before_the_total_is_reached_fails_the_whole_list()
    {
        var (client, handler) = Create((request, _) => request.RequestUri!.Query.Contains("page=1")
            ? Reply(HttpStatusCode.OK, ListPage(5, "A", "B"))
            : Reply(HttpStatusCode.OK, ListPage(5)));

        var result = await client.ListAsync(DateTimeOffset.UnixEpoch, DateTimeOffset.UtcNow, CancellationToken.None);

        Assert.False(result.Succeeded);
        Assert.Empty(result.Records);
        Assert.Contains("Sayfa 2 boş", result.Error);
        Assert.Equal(2, handler.Calls);
    }

    [Fact]
    public async Task A_failing_second_page_fails_the_whole_list_and_returns_no_records()
    {
        var (client, _) = Create((request, _) => request.RequestUri!.Query.Contains("page=1")
            ? Reply(HttpStatusCode.OK, ListPage(3, "A", "B"))
            : Reply(HttpStatusCode.InternalServerError, "{}"));

        var result = await client.ListAsync(DateTimeOffset.UnixEpoch, DateTimeOffset.UtcNow, CancellationToken.None);

        Assert.False(result.Succeeded);
        Assert.Empty(result.Records);
        Assert.Contains("500", result.Error);
        Assert.Contains("sayfa 2", result.Error);
    }

    [Fact]
    public async Task A_list_that_cannot_be_reached_or_read_fails()
    {
        var (unreachable, _) = Create((_, _) => throw new HttpRequestException("connection refused"));
        var (timedOut, _) = Create(async (_, ct) => { await Task.Delay(Timeout.Infinite, ct); return null!; }, TimeSpan.FromMilliseconds(50));
        var (garbage, _) = Create((_, _) => Reply(HttpStatusCode.OK, "not json"));

        foreach (var client in new[] { unreachable, timedOut, garbage })
        {
            var result = await client.ListAsync(DateTimeOffset.UnixEpoch, DateTimeOffset.UtcNow, CancellationToken.None);

            Assert.False(result.Succeeded);
            Assert.NotNull(result.Error);
        }
    }
}
