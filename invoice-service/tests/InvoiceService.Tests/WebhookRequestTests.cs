using InvoiceService.Webhooks;

namespace InvoiceService.Tests;

public class WebhookRequestTests
{
    private static readonly DateTimeOffset At = new(2026, 10, 1, 12, 0, 0, TimeSpan.Zero);

    private static ErpWebhookRequest Valid(string type = "invoice.approved", string? reason = null) =>
        new("e-1", type, "FTR-000001", "ERP-1", At, reason);

    [Theory]
    [InlineData("invoice.received")]
    [InlineData("invoice.approved")]
    public void Valid_events_have_no_errors(string type) => Assert.Empty(Valid(type).Validate());

    [Fact]
    public void Rejected_event_needs_a_reason()
    {
        Assert.Equal(["reason"], Valid("invoice.rejected").Validate().Keys);
        Assert.Empty(Valid("invoice.rejected", "Vergi numarası geçersiz").Validate());
    }

    [Fact]
    public void Unknown_event_type_is_invalid() =>
        Assert.Contains("event_type", Valid("invoice.paid").Validate().Keys);

    [Fact]
    public void Missing_fields_are_all_reported()
    {
        var errors = new ErpWebhookRequest(null, null, null, null, null, null).Validate();
        Assert.Equal(
            ["erp_reference", "event_id", "event_type", "invoice_number", "occurred_at"],
            errors.Keys.Order().ToArray());
    }

    [Fact]
    public void Values_longer_than_the_columns_are_invalid()
    {
        var errors = new ErpWebhookRequest(new string('e', 65), "invoice.received", new string('f', 33), new string('r', 33), At, null).Validate();
        Assert.Equal(["erp_reference", "event_id", "invoice_number"], errors.Keys.Order().ToArray());
    }
}
