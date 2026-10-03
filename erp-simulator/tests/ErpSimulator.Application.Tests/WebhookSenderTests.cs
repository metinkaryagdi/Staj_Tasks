using ErpSimulator.Application.Tests.Fakes;
using ErpSimulator.Application.Webhooks;
using ErpSimulator.Domain.Webhooks;
using Microsoft.Extensions.Logging.Abstractions;
using Microsoft.Extensions.Options;

namespace ErpSimulator.Application.Tests;

/// <summary>One webhook send with the invoice service and the database replaced by in-memory ports.</summary>
public class WebhookSenderTests
{
    private static readonly DateTimeOffset Now = new(2026, 10, 3, 10, 0, 0, TimeSpan.Zero);
    private const string Secret = "dev-only-erp-webhook-secret-do-not-use-in-production";

    private readonly FakeTransport _transport = new();
    private readonly FakeDeliveryStore _deliveries = new();
    private readonly FakeUnitOfWork _unitOfWork = new();

    private WebhookSender Sender() => new(_transport, _deliveries, _unitOfWork, Options.Create(new WebhookOptions
    {
        TargetUrl = "http://invoice/api/v1/erp-webhooks", Secret = Secret, TimeoutSeconds = 5,
        RetryDelaysSeconds = [5, 10, 20, 40, 80], Problems = new WebhookProblems { ReplayAgeSeconds = 600 }
    }), new FixedTime(Now), NullLogger<WebhookSender>.Instance);

    private static WebhookDelivery Row(string kind = DeliveryKind.Normal, int attempts = 0) => new()
    {
        Id = 7, EventId = "evt-1", EventType = ErpEventType.Approved, InvoiceNumber = "FTR-000001", Kind = kind,
        Payload = """{"event_id":"evt-1"}""", DueAt = Now, Status = DeliveryStatus.Pending, AttemptCount = attempts
    };

    [Fact]
    public async Task Delivered_event_is_signed_with_the_shared_secret_and_releases_its_replays()
    {
        await Sender().SendAsync(Row(), CancellationToken.None);

        var post = Assert.Single(_transport.Posts);
        Assert.Equal(Now.ToUnixTimeSeconds().ToString(), post.Timestamp);
        Assert.Equal(WebhookSignature.Compute(Secret, post.Timestamp, System.Text.Encoding.UTF8.GetBytes(post.Body)), post.Signature);
        var recorded = Assert.Single(_deliveries.Recorded);
        Assert.Equal((DeliveryStatus.Delivered, 1, Now), (recorded.Status, recorded.Attempt, recorded.CompletedAt));
        Assert.Equal(["evt-1"], _deliveries.Released);
        Assert.Equal(1, _unitOfWork.Committed);
    }

    [Fact]
    public async Task Server_error_is_retried_counted_from_when_the_send_started()
    {
        _transport.Result = new(500, "HTTP 500");

        await Sender().SendAsync(Row(attempts: 1), CancellationToken.None);

        var recorded = Assert.Single(_deliveries.Recorded);
        Assert.Equal(DeliveryStatus.Pending, recorded.Status);
        Assert.Equal(Now.AddSeconds(10), recorded.NextDue); // second retry: RetryDelaysSeconds[1]
        Assert.Null(recorded.CompletedAt);
        Assert.Empty(_deliveries.Released);
    }

    [Fact]
    public async Task Last_retry_without_success_fails_and_skips_the_replays()
    {
        _transport.Result = new(null, "no answer within 5 s");

        await Sender().SendAsync(Row(attempts: 5), CancellationToken.None);

        Assert.Equal(DeliveryStatus.Failed, Assert.Single(_deliveries.Recorded).Status);
        Assert.Equal(["evt-1"], _deliveries.Skipped);
    }

    [Fact]
    public async Task Fake_event_is_signed_with_another_key_and_a_4xx_rejects_it_for_good()
    {
        _transport.Result = new(401, "HTTP 401");

        await Sender().SendAsync(Row(DeliveryKind.Fake), CancellationToken.None);

        var post = Assert.Single(_transport.Posts);
        Assert.NotEqual(WebhookSignature.Compute(Secret, post.Timestamp, System.Text.Encoding.UTF8.GetBytes(post.Body)), post.Signature);
        Assert.Equal(DeliveryStatus.Rejected, Assert.Single(_deliveries.Recorded).Status);
    }

    [Fact]
    public async Task Replay_carries_a_timestamp_from_ten_minutes_ago()
    {
        await Sender().SendAsync(Row(DeliveryKind.Replay), CancellationToken.None);

        Assert.Equal(Now.AddSeconds(-600).ToUnixTimeSeconds().ToString(), Assert.Single(_transport.Posts).Timestamp);
        Assert.Empty(_deliveries.Released); // only a normal event releases replays
    }

    [Fact]
    public async Task Send_cut_off_by_shutdown_records_nothing()
    {
        _transport.ThrowStopping = true;
        using var stopping = new CancellationTokenSource();
        await stopping.CancelAsync();

        await Sender().SendAsync(Row(), stopping.Token);

        Assert.Empty(_deliveries.Recorded);
        Assert.Equal(0, _unitOfWork.Committed);
    }
}
