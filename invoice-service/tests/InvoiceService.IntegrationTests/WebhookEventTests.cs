using InvoiceService.Domain.Invoices;
using InvoiceService.Domain.Webhooks;
using InvoiceService.IntegrationTests.Support;

namespace InvoiceService.IntegrationTests;

/// <summary>ERP events reaching the service: before the invoice is Gönderildi, and several times at once.</summary>
public class WebhookEventTests(PostgresFixture postgres) : IntegrationTest(postgres)
{
    private Task<string?> InvoiceStatusAsync(string number) =>
        ScalarAsync<string>("SELECT status FROM invoices WHERE invoice_number = @n", ("n", number));

    private Task<string?> EventStatusAsync(string eventId) =>
        ScalarAsync<string>("SELECT status FROM erp_webhook_events WHERE event_id = @e", ("e", eventId));

    // Scenario 3
    [Fact]
    public async Task An_event_that_comes_before_the_invoice_is_Gonderildi_waits_and_is_applied_when_it_is()
    {
        var number = await CreateInvoiceAsync();

        var result = await DeliverAsync(ErpEvent("evt-1", WebhookEventType.Approved, number));

        // Kept, not lost and not applied: the invoice has not reached the ERP yet.
        Assert.Equal(WebhookEventStatus.Pending, result.Status);
        Assert.Equal(WebhookEventStatus.Pending, await EventStatusAsync("evt-1"));
        Assert.Equal(InvoiceStatus.Pending, await InvoiceStatusAsync(number));

        await SendToErpAsync();

        Assert.Equal(InvoiceStatus.Approved, await InvoiceStatusAsync(number));
        Assert.Equal(WebhookEventStatus.Processed, await EventStatusAsync("evt-1"));
        Assert.True(await ScalarAsync<bool>("SELECT processed_at IS NOT NULL FROM erp_webhook_events WHERE event_id = 'evt-1'"));
    }

    // Scenario 4
    [Fact]
    public async Task The_same_event_arriving_ten_times_at_once_is_processed_once()
    {
        var number = await CreateInvoiceAsync();
        await SendToErpAsync();
        Assert.Equal(InvoiceStatus.Sent, await InvoiceStatusAsync(number));
        var request = ErpEvent("evt-1", WebhookEventType.Approved, number);

        var start = new TaskCompletionSource();
        var deliveries = Enumerable.Range(0, 10).Select(async _ =>
        {
            await start.Task;
            return await DeliverAsync(request);
        }).ToList();
        start.SetResult();
        var results = await Task.WhenAll(deliveries);

        Assert.Single(results, r => !r.Repeat);
        Assert.Equal(9, results.Count(r => r.Repeat));
        Assert.Equal(1L, await ScalarAsync<long>("SELECT count(*) FROM erp_webhook_events"));
        Assert.Equal(10, await ScalarAsync<int>("SELECT delivery_count FROM erp_webhook_events WHERE event_id = 'evt-1'"));
        // Applied once: a second application would have found the invoice already Onaylandı and marked the event Yok Sayıldı.
        Assert.Equal(WebhookEventStatus.Processed, await EventStatusAsync("evt-1"));
        Assert.Null(await ScalarAsync<string>("SELECT ignore_reason FROM erp_webhook_events WHERE event_id = 'evt-1'"));
        Assert.Equal(InvoiceStatus.Approved, await InvoiceStatusAsync(number));
    }
}
