using InvoiceService.Application.Webhooks;

namespace InvoiceService.Application.Tests;

public class WebhookRequestTests
{
    private static readonly DateTimeOffset At = new(2026, 10, 1, 12, 0, 0, TimeSpan.Zero);

    private static ErpWebhookRequest Valid(string type = "invoice.approved", string? reason = null) =>
        new("e-1", type, "FTR-000001", "ERP-1", At, reason);

    private static byte[] Utf8(string json) => System.Text.Encoding.UTF8.GetBytes(json);

    [Fact]
    public void An_event_in_the_new_format_reads_the_same_as_in_the_old()
    {
        var parsed = ErpWebhookRequest.Parse(Utf8("""
            {"schema":"erp.invoice-event.v2","id":"e-1","type":"invoice.rejected","occurredAt":"2026-10-01T12:00:00+00:00",
             "invoice":{"number":"FTR-000001","erpReference":"ERP-1"},"reason":"Vergi"}
            """));

        Assert.Equal(new ErpWebhookRequest("e-1", "invoice.rejected", "FTR-000001", "ERP-1", At, "Vergi"), parsed);
        Assert.Empty(parsed!.Validate());
    }

    [Fact]
    public void An_event_in_the_old_format_still_reads()
    {
        var parsed = ErpWebhookRequest.Parse(Utf8("""
            {"event_id":"e-1","event_type":"invoice.approved","invoice_number":"FTR-000001","erp_reference":"ERP-1","occurred_at":"2026-10-01T12:00:00+00:00"}
            """));

        Assert.Equal(new ErpWebhookRequest("e-1", "invoice.approved", "FTR-000001", "ERP-1", At, null), parsed);
    }

    [Fact]
    public void An_unknown_schema_is_not_read()
    {
        Assert.Null(ErpWebhookRequest.Parse(Utf8("""{"schema":"erp.invoice-event.v9","id":"e-1"}""")));
    }

    [Fact]
    public void A_new_format_event_without_its_invoice_fails_validation()
    {
        var parsed = ErpWebhookRequest.Parse(Utf8("""{"schema":"erp.invoice-event.v2","id":"e-1","type":"invoice.approved"}"""));

        Assert.Contains("invoice_number", parsed!.Validate().Keys);
    }

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
