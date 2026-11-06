using InvoiceService.Application.Abstractions;
using InvoiceService.Application.Invoices;
using InvoiceService.Application.Reconciliation;
using InvoiceService.Application.Webhooks;
using InvoiceService.Domain.Invoices;
using InvoiceService.Domain.Operators;
using InvoiceService.Domain.Reconciliation;
using InvoiceService.Domain.Webhooks;
using InvoiceService.IntegrationTests.Support;
using Microsoft.Extensions.DependencyInjection;

namespace InvoiceService.IntegrationTests;

/// <summary>Moving between the ERP's API versions on a real database, with the ERP answering in each version.</summary>
public class ErpVersionMoveTests(PostgresFixture postgres) : IntegrationTest(postgres)
{
    private static readonly OperatorIdentity Operator = new("Test Operatör", "sub-1");

    private async Task SetShareAsync(int percent)
    {
        await using var scope = NewScope();
        await scope.ServiceProvider.GetRequiredService<IErpVersionSetting>().SetV2PercentAsync(percent, CancellationToken.None);
    }

    private async Task<CancelStatus> CancelAsync(string number)
    {
        await using var scope = NewScope();
        return await scope.ServiceProvider.GetRequiredService<CancelInvoiceHandler>().HandleAsync(number, Operator);
    }

    private Task<string?> StatusAsync(string number) =>
        ScalarAsync<string>("SELECT status FROM invoices WHERE invoice_number = @n", ("n", number));

    private Task<int> AttemptsAsync(string number) =>
        ScalarAsync<int>("SELECT send_attempt_count FROM invoices WHERE invoice_number = @n", ("n", number));

    [Fact]
    public async Task A_new_database_starts_on_v1_and_the_share_changes_for_the_next_request()
    {
        Erp.KeepRecords = true;
        var first = await CreateInvoiceAsync();
        await SendAllAsync();
        Assert.Contains("/api/v1/invoices", Erp.Paths);
        Assert.DoesNotContain("/api/v2/invoices", Erp.Paths);

        await SetShareAsync(100);
        var second = await CreateInvoiceAsync();
        await SendAllAsync();

        Assert.Contains("/api/v2/invoices", Erp.Paths);
        Assert.False(Erp.KurusPosted.ContainsKey(first));
        Assert.Equal(1000L, Erp.KurusPosted[second]);
    }

    [Fact]
    public async Task An_invoice_sent_with_v1_is_cancelled_through_v2_after_the_move()
    {
        Erp.KeepRecords = true;
        var number = await CreateInvoiceAsync();
        await SendAllAsync();
        await SetShareAsync(100);
        Erp.V1Closed = true;

        Assert.Equal(CancelStatus.Queued, await CancelAsync(number));
        await SendAllAsync();

        Assert.Contains($"/api/v2/invoices/{number}/cancel", Erp.Paths);
        Assert.Equal(1, Erp.CancellationCount);
        Assert.DoesNotContain(Erp.Paths, p => p.StartsWith("/api/v1") && p.EndsWith("/cancel"));
    }

    [Fact]
    public async Task Closing_v1_with_invoices_and_cancellations_queued_leaves_nothing_failed_or_stuck()
    {
        Erp.KeepRecords = true;
        var sent = await CreateInvoiceAsync();
        await SendAllAsync();
        var queued = await CreateInvoiceAsync();
        Assert.Equal(CancelStatus.Queued, await CancelAsync(sent));
        // The share is still 0: only the 410 can move them to v2.
        Erp.V1Closed = true;

        await SendAllAsync();

        Assert.Equal(1, await AttemptsAsync(queued)); // the 410 used up no attempt
        Assert.Equal(InvoiceStatus.Sent, await StatusAsync(queued));
        Assert.Equal(1, Erp.CancellationCount);
        Assert.Equal(0L, await ScalarAsync<long>("SELECT count(*) FROM erp_outbox WHERE status <> 'Tamamlandı'"));
    }

    [Fact]
    public async Task A_reconciliation_run_with_v1_closed_and_the_share_back_at_0_is_not_failed()
    {
        Erp.V1Closed = true;

        await using var scope = NewScope();
        var started = await scope.ServiceProvider.GetRequiredService<ReconciliationService>().TryStartAsync(by: null, CancellationToken.None);
        await scope.ServiceProvider.GetRequiredService<ReconciliationRunner>().RunAsync(started!.Run, CancellationToken.None);
        await started.Lease.DisposeAsync();

        Assert.Equal(ReconciliationStatus.Completed,
            await ScalarAsync<string>("SELECT status FROM reconciliation_runs WHERE id = @i", ("i", started.Run.Id)));
        Assert.Contains("/api/v2/invoices", Erp.Paths);
    }

    [Fact]
    public async Task With_v2_not_there_yet_an_invoice_is_tried_again_and_not_failed()
    {
        Erp.OnPost = _ => Microsoft.AspNetCore.Http.Results.Problem(statusCode: 404, title: "Not Found");
        await SetShareAsync(100);
        var number = await CreateInvoiceAsync();

        await SendToErpAsync();

        Assert.Equal(InvoiceStatus.Pending, await StatusAsync(number));

        // The ERP's address is back: the invoice goes, whichever attempt it is.
        Erp.AcceptInvoices();
        await ExecuteAsync("UPDATE erp_outbox SET next_attempt_at = now(), locked_until = NULL");
        await SendToErpAsync();
        Assert.Equal(InvoiceStatus.Sent, await StatusAsync(number));
    }

    [Fact]
    public async Task A_rejection_in_the_new_format_keeps_its_reason()
    {
        var number = await CreateInvoiceAsync();
        await SendAllAsync();
        var payload = $$"""{"schema":"erp.invoice-event.v2","id":"evt-v2","type":"invoice.rejected","occurredAt":"{{DateTimeOffset.UtcNow:O}}","invoice":{"number":"{{number}}","erpReference":"ERP-{{number}}"},"reason":"Vergi numarası geçersiz"}""";

        await using var scope = NewScope();
        await scope.ServiceProvider.GetRequiredService<WebhookEventProcessor>().ReceiveAsync(
            ErpWebhookRequest.Parse(System.Text.Encoding.UTF8.GetBytes(payload))!, payload, CancellationToken.None);

        Assert.Equal(InvoiceStatus.Rejected, await StatusAsync(number));
        Assert.Equal("Vergi numarası geçersiz",
            await ScalarAsync<string>("SELECT reject_reason FROM invoices WHERE invoice_number = @n", ("n", number)));
    }
}
