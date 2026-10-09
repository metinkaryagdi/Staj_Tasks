using InvoiceService.Application.Abstractions;
using InvoiceService.Application.Invoices;
using InvoiceService.Application.Reconciliation;
using InvoiceService.Domain.Invoices;
using InvoiceService.Domain.Outbox;
using InvoiceService.Domain.Reconciliation;
using InvoiceService.Domain.Webhooks;
using InvoiceService.IntegrationTests.Support;
using Microsoft.Extensions.DependencyInjection;

namespace InvoiceService.IntegrationTests;

/// <summary>A reconciliation fix and another change to the same invoice at the same moment.</summary>
public class ReconciliationFixRaceTests(PostgresFixture postgres) : IntegrationTest(postgres)
{
    /// <summary>Invoices that are Gönderildi: sent by the worker, no event so far.</summary>
    private async Task<List<string>> SentInvoicesAsync(int count)
    {
        var numbers = new List<string>();
        for (var i = 0; i < count; i++)
            numbers.Add(await CreateInvoiceAsync());
        await SendAllAsync();
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
                return await ApplyFixAsync(runId, new PlannedFinding(number, FindingType.StuckInvoice, "karar uygulandı", fix));
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

    // Scenario 7
    [Fact]
    public async Task A_fix_of_a_Failed_invoice_and_a_resend_at_the_same_moment_leave_it_in_one_consistent_state()
    {
        const int pairs = 40;
        var runId = await StartRunAsync();

        // Invoices the ERP refused, so they are Başarısız; the ERP has them, as far as the fix is concerned.
        Erp.RefuseInvoices();
        var numbers = new List<string>();
        for (var i = 0; i < pairs; i++)
            numbers.Add(await CreateInvoiceAsync());
        await SendAllAsync();
        Assert.Equal((long)pairs, await ScalarAsync<long>("SELECT count(*) FROM invoices WHERE status = 'Başarısız'"));
        Erp.AcceptInvoices();

        var start = new TaskCompletionSource();
        var pairsRunning = numbers.Select(number =>
        {
            var fix = Task.Run(async () =>
            {
                await start.Task;
                var recover = new Fix(FixKind.RecoverFailed, number, InvoiceStatus.Failed, $"ERP-{number}", ErpDecision.None);
                return await ApplyFixAsync(runId, new PlannedFinding(number, FindingType.FailedButInErp, "ERP'de kayıtlı", recover));
            });
            var resend = Task.Run(async () =>
            {
                await start.Task;
                await using var scope = NewScope();
                return await scope.ServiceProvider.GetRequiredService<ResendInvoiceHandler>().HandleAsync(number, "operator");
            });
            return (Number: number, Fix: fix, Resend: resend);
        }).ToList();
        start.SetResult();
        await Task.WhenAll(pairsRunning.SelectMany(p => new Task[] { p.Fix, p.Resend }));

        // Either the resend came first (queued again, the fix left it alone) or the fix did (Gönderildi, the resend refused).
        var inconsistent = new List<string>();
        foreach (var (number, fixTask, resendTask) in pairsRunning)
        {
            var fixed_ = await fixTask;
            var resend = (await resendTask).Status;
            var status = await ScalarAsync<string>("SELECT status FROM invoices WHERE invoice_number = @n", ("n", number));
            var outbox = await ScalarAsync<string>("SELECT status FROM erp_outbox WHERE invoice_number = @n", ("n", number));
            var reference = await ScalarAsync<string>("SELECT erp_reference FROM invoices WHERE invoice_number = @n", ("n", number));
            var findings = await ScalarAsync<long>(
                "SELECT count(*) FROM reconciliation_findings WHERE invoice_number = @n AND action = 'Düzeltildi'", ("n", number));

            var resendWon = !fixed_ && resend == ResendStatus.Queued
                && status == InvoiceStatus.Pending && outbox == OutboxStatus.Pending && findings == 0;
            var fixWon = fixed_ && resend == ResendStatus.NotFailed
                && status == InvoiceStatus.Sent && reference == $"ERP-{number}" && outbox == OutboxStatus.Completed && findings == 1;
            if (resendWon == fixWon)
                inconsistent.Add($"{number}: fix={fixed_}, resend={resend}, invoice={status}, outbox={outbox}, reference={reference}, findings={findings}");
        }
        Assert.Empty(inconsistent);

        // The ones queued again are sent and end up like the others.
        await SendAllAsync();
        Assert.Equal((long)pairs, await ScalarAsync<long>(
            "SELECT count(*) FROM invoices i JOIN erp_outbox o USING (invoice_number) WHERE i.status = 'Gönderildi' AND o.status = 'Tamamlandı'"));
    }
}
