using System.Text;
using InvoiceService.Application.Webhooks;
using Microsoft.Extensions.Configuration;

namespace InvoiceService.Application.Tests;

public class WebhookSignatureTests
{
    private const string Secret = "test-secret-that-is-at-least-32-bytes-long";
    private static readonly DateTimeOffset Now = DateTimeOffset.FromUnixTimeSeconds(1_790_000_000);
    private static readonly byte[] Body = Encoding.UTF8.GetBytes("""{"event_id":"e-1","event_type":"invoice.received"}""");

    private static string Ts(long secondsFromNow) => (Now.ToUnixTimeSeconds() + secondsFromNow).ToString();

    private static SignatureCheck Verify(string? timestamp, string? signature, byte[]? body = null) =>
        WebhookSignature.Verify(Secret, timestamp, signature, body ?? Body, Now, toleranceSeconds: 300);

    [Fact]
    public void Known_vector_matches_the_documented_format()
    {
        // HMAC-SHA256("key", "1.{}"), computed independently: lowercase hex of the timestamp, a dot and the raw body.
        Assert.Equal(
            Convert.ToHexStringLower(System.Security.Cryptography.HMACSHA256.HashData("key"u8, "1.{}"u8)),
            WebhookSignature.Compute("key", "1", "{}"u8));
    }

    [Fact]
    public void Correct_signature_is_valid()
    {
        var ts = Ts(0);
        Assert.Equal(SignatureCheck.Valid, Verify(ts, WebhookSignature.Compute(Secret, ts, Body)));
    }

    [Fact]
    public void Uppercase_hex_is_the_same_signature()
    {
        var ts = Ts(0);
        Assert.Equal(SignatureCheck.Valid, Verify(ts, WebhookSignature.Compute(Secret, ts, Body).ToUpperInvariant()));
    }

    [Theory]
    [InlineData(null, "sig")]
    [InlineData("1790000000", null)]
    [InlineData("", "sig")]
    [InlineData("1790000000", "")]
    public void Missing_headers(string? timestamp, string? signature)
    {
        Assert.Equal(SignatureCheck.MissingHeaders, Verify(timestamp, signature));
    }

    [Theory]
    [InlineData("abc")]
    [InlineData("-1790000000")]
    [InlineData("+1790000000")]
    [InlineData(" 1790000000")]
    [InlineData("1790000000.5")]
    [InlineData("99999999999999999999")]
    public void Timestamp_must_be_plain_unix_seconds(string timestamp)
    {
        Assert.Equal(SignatureCheck.BadTimestamp, Verify(timestamp, new string('0', 64)));
    }

    [Fact]
    public void Exactly_tolerance_old_or_ahead_is_accepted()
    {
        foreach (var offset in new[] { -300L, 300L })
        {
            var ts = Ts(offset);
            Assert.Equal(SignatureCheck.Valid, Verify(ts, WebhookSignature.Compute(Secret, ts, Body)));
        }
    }

    [Fact]
    public void Older_than_tolerance_is_expired_even_with_a_valid_signature()
    {
        var ts = Ts(-301);
        Assert.Equal(SignatureCheck.Expired, Verify(ts, WebhookSignature.Compute(Secret, ts, Body)));
        var tenMinutes = Ts(-600);
        Assert.Equal(SignatureCheck.Expired, Verify(tenMinutes, WebhookSignature.Compute(Secret, tenMinutes, Body)));
    }

    [Fact]
    public void Further_ahead_than_tolerance_is_rejected()
    {
        var ts = Ts(301);
        Assert.Equal(SignatureCheck.FromFuture, Verify(ts, WebhookSignature.Compute(Secret, ts, Body)));
    }

    [Fact]
    public void Wrong_secret_is_a_bad_signature()
    {
        var ts = Ts(0);
        Assert.Equal(SignatureCheck.BadSignature, Verify(ts, WebhookSignature.Compute("another-secret-of-at-least-32-bytes!!", ts, Body)));
    }

    [Fact]
    public void Changed_body_is_a_bad_signature()
    {
        var ts = Ts(0);
        var signature = WebhookSignature.Compute(Secret, ts, Body);
        var changed = Encoding.UTF8.GetBytes("""{"event_id":"e-1","event_type":"invoice.approved"}""");
        Assert.Equal(SignatureCheck.BadSignature, Verify(ts, signature, changed));
    }

    [Fact]
    public void Signature_for_another_timestamp_is_bad()
    {
        // A replayed event with a fresh timestamp but its old signature.
        var signature = WebhookSignature.Compute(Secret, Ts(-600), Body);
        Assert.Equal(SignatureCheck.BadSignature, Verify(Ts(0), signature));
    }

    [Theory]
    [InlineData("zz")]
    [InlineData("abcd")]
    public void Malformed_signature_is_bad(string signature)
    {
        Assert.Equal(SignatureCheck.BadSignature, Verify(Ts(0), signature));
        Assert.Equal(SignatureCheck.BadSignature, Verify(Ts(0), new string('z', 64)));
    }

    private static IConfiguration Settings(
        string? secret = Secret, string? tolerance = "300", string? maxBody = "65536", string? budget = "4000",
        string? lockTimeout = "2000") =>
        new ConfigurationBuilder().AddInMemoryCollection(new Dictionary<string, string?>
        {
            ["ErpWebhooks:Secret"] = secret,
            ["ErpWebhooks:ToleranceSeconds"] = tolerance,
            ["ErpWebhooks:MaxBodyBytes"] = maxBody,
            ["ErpWebhooks:ResponseBudgetMilliseconds"] = budget,
            ["ErpWebhooks:LockTimeoutMilliseconds"] = lockTimeout
        }).Build();

    private static bool Validates(IConfiguration configuration)
    {
        var options = new WebhookOptions();
        configuration.GetSection(WebhookOptions.SectionName).Bind(options);
        return new WebhookOptionsValidator(configuration).Validate(null, options).Succeeded;
    }

    [Fact]
    public void Settings_file_values_are_valid() => Assert.True(Validates(Settings()));

    [Theory]
    [InlineData(null, "300", "65536")]
    [InlineData("too-short", "300", "65536")]
    [InlineData(Secret, null, "65536")]
    [InlineData(Secret, "0", "65536")]
    [InlineData(Secret, "300", "0")]
    public void Invalid_settings_stop_the_app(string? secret, string? tolerance, string? maxBody) =>
        Assert.False(Validates(Settings(secret, tolerance, maxBody)));

    [Theory]
    [InlineData(null, "2000")]   // missing
    [InlineData("0", "2000")]
    [InlineData("5000", "2000")] // the response limit itself leaves no time for the answer
    [InlineData("6000", "2000")]
    [InlineData("4000", null)]   // missing
    [InlineData("4000", "0")]
    [InlineData("4000", "4000")] // the lock wait must end before the budget
    public void Response_limits_must_fit_in_five_seconds(string? budget, string? lockTimeout) =>
        Assert.False(Validates(Settings(budget: budget, lockTimeout: lockTimeout)));
}
