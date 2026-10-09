using InvoiceService.Application.Abstractions;
using InvoiceService.Application.Reconciliation;
using InvoiceService.Domain.Invoices;
using InvoiceService.Domain.Reconciliation;
using InvoiceService.Domain.Webhooks;
using InvoiceService.IntegrationTests.Support;
using Microsoft.Extensions.DependencyInjection;

namespace InvoiceService.IntegrationTests;

/// <summary>A reconciliation fix and another change to the same invoice at the same moment.</summary>
public class ReconciliationFixRaceTests(PostgresFixture postgres) : IntegrationTest(postgres)
{
    private async Task<long> StartRunAsync()
    {
        await using var scope = NewScope();
        var started = await scope.ServiceProvider.GetRequiredService<ReconciliationService>()
            .TryStartAsync(operatorName: null, CancellationToken.None);
        await started!.Lease.DisposeAsync();
        return started.Run.Id;
    }

    private async Task<bool> ApplyAsync(long runId, PlannedFinding finding)
    {
        await using var scope = NewScope();
        return await scope.ServiceProvider.GetRequiredService<FixApplier>().ApplyAsync(runId, finding);
    }

    /// <summary>Invoices that are Gönderildi, sent by the worker without an event so far.</summary>
    private async Task<List<string>> SentInvoicesAsync(int count)
    {
        var numbers = new List<string>();
        for (var i = 0; i < count; i++)
            numbers.Add(await CreateInvoiceAsync());
        while (await ScalarAsync<long>("SELECT count(*) FROM erp_outbox WHERE status = 'Bekliyor'") > 0)
            await SendToErpAsync();
        return numbers;
    }

    // Scenario 6
    [Fact]
    public async Task A_fix_and_an_event_for_the_same_invoice_at_the_same_moment_do_not_spoil_each_other()
    {
        const int pairs = 40;
        var runId = await StartRunAsync();
        var numbers = await SentInvoicesAsync(pairs);

        // For each invoice the ERP has decided "approved": the run fixes it, and the event for the same decision arrives.
        var start = new TaskCompletionSource();
        var work = numbers.SelectMany(number => new[]
        {
            Task.Run(async () =>
            {
                await start.Task;
                var fix = new Fix(FixKind.ApplyDecision, number, InvoiceStatus.Sent, $"ERP-{number}", new ErpDecision(ErpDecisionKind.Approved));
                return await ApplyAsync(runId, new PlannedFinding(number, FindingType.StuckInvoice, "karar uygulandı", fix));
            }),
            Task.Run(async () =>
            {
                await start.Task;
                await DeliverAsync(ErpEvent($"evt-{number}", WebhookEventType.Approved, number));
                return false;
            })
        }).ToList();
        start.SetResult();
        await Task.WhenAll(work);

        // Whoever got the invoice first changed it; the other found it already Onaylandı and left it alone. Never both.
        var inconsistent = new List<string>();
        foreach (var number in numbers)
        {
            var status = await ScalarAsync<string>("SELECT status FROM invoices WHERE invoice_number = @n", ("n", number));
            var fixes = await ScalarAsync<long>(
                "SELECT count(*) FROM reconciliation_findings WHERE invoice_number = @n AND action = 'Düzeltildi'", ("n", number));
            var eventStatus = await ScalarAsync<string>("SELECT status FROM erp_webhook_events WHERE invoice_number = @n", ("n", number));

            var fixWon = fixes == 1 && eventStatus == WebhookEventStatus.Ignored;
            var eventWon = fixes == 0 && eventStatus == WebhookEventStatus.Processed;
            if (status != InvoiceStatus.Approved || fixWon == eventWon)
                inconsistent.Add($"{number}: invoice={status}, fixes={fixes}, event={eventStatus}");
        }
        Assert.Empty(inconsistent);
    }
}
