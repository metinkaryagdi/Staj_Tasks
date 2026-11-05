using InvoiceService.Application.Abstractions;
using InvoiceService.Application.Invoices;
using InvoiceService.Application.Outbox;
using InvoiceService.Application.Reconciliation;
using InvoiceService.Domain.Invoices;
using InvoiceService.Domain.Operators;
using InvoiceService.Domain.Outbox;
using InvoiceService.Domain.Reconciliation;
using InvoiceService.Domain.Webhooks;
using InvoiceService.IntegrationTests.Support;
using Microsoft.AspNetCore.Http;
using Microsoft.Extensions.DependencyInjection;

namespace InvoiceService.IntegrationTests;

/// <summary>
/// An invoice's cancellation never reaches the ERP before the invoice: the claim query decides, so these run against the
/// database.
/// </summary>
public class CancelOrderTests(PostgresFixture postgres) : IntegrationTest(postgres)
{
    private static readonly OperatorIdentity Operator = new("Test Operatör", "sub-1");

    private async Task<CancelStatus> CancelAsync(string number)
    {
        await using var scope = NewScope();
        return await scope.ServiceProvider.GetRequiredService<CancelInvoiceHandler>().HandleAsync(number, Operator);
    }

    private async Task<IReadOnlyList<ClaimedEntry>> ClaimAsync(string workerId, DateTimeOffset now, int lockSeconds = 60)
    {
        await using var scope = NewScope();
        return await scope.ServiceProvider.GetRequiredService<IOutboxStore>()
            .ClaimAsync(10, workerId, now, now.AddSeconds(lockSeconds), 10, CancellationToken.None);
    }

    private async Task SendAsync(ClaimedEntry entry, string workerId)
    {
        await using var scope = NewScope();
        await scope.ServiceProvider.GetRequiredService<OutboxProcessor>().SendAsync(entry, workerId);
    }

    private async Task<ResendStatus> ResendAsync(string number)
    {
        await using var scope = NewScope();
        return (await scope.ServiceProvider.GetRequiredService<ResendInvoiceHandler>().HandleAsync(number, Operator)).Status;
    }

    private Task<string?> OutboxStatusAsync(string number, string kind) =>
        ScalarAsync<string>("SELECT status FROM erp_outbox WHERE invoice_number = @n AND kind = @k", ("n", number), ("k", kind));

    private Task<string?> InvoiceStatusAsync(string number) =>
        ScalarAsync<string>("SELECT status FROM invoices WHERE invoice_number = @n", ("n", number));

    private async Task<string> InvoiceAtTheErpAsync()
    {
        Erp.KeepRecords = true;
        var number = await CreateInvoiceAsync();
        await SendToErpAsync();
        return number;
    }

    [Fact]
    public async Task A_cancellation_waits_while_the_invoice_waits_for_a_retry_and_goes_after_it_reaches_the_erp()
    {
        // The ERP saves the invoice but answers with an error, so the service does not know the invoice is there.
        Erp.KeepRecords = true;
        var number = await CreateInvoiceAsync();
        Erp.OnPost = n => { Erp.RecordInvoice(n); return Results.Problem(statusCode: 500, title: "ERP hatası"); };
        await SendToErpAsync();
        Assert.Equal(OutboxStatus.Pending, await OutboxStatusAsync(number, OutboxKind.Send));

        Assert.Equal(CancelStatus.Queued, await CancelAsync(number));

        // The invoice's retry is not due yet; the cancellation is due now but is not taken.
        Assert.Empty(await ClaimAsync("A", DateTimeOffset.UtcNow));
        Assert.Equal(["POST " + number], Erp.Requests);

        // The retry finds the invoice at the ERP; only then is the cancellation taken and sent.
        var retry = Assert.Single(await ClaimAsync("A", DateTimeOffset.UtcNow.AddMinutes(10)));
        Assert.Equal(OutboxKind.Send, retry.Kind);
        await SendAsync(retry, "A");
        var cancel = Assert.Single(await ClaimAsync("A", DateTimeOffset.UtcNow.AddMinutes(10)));
        Assert.Equal(OutboxKind.Cancel, cancel.Kind);
        await SendAsync(cancel, "A");

        Assert.Equal(["POST " + number, "CANCEL " + number], Erp.Requests);
        Assert.Equal(OutboxStatus.Completed, await OutboxStatusAsync(number, OutboxKind.Cancel));
        Assert.Equal(1, Erp.CancellationCount);
    }

    [Fact]
    public async Task The_cancellation_of_an_invoice_at_the_erp_goes_before_the_unrelated_invoices_queued_before_it()
    {
        var number = await InvoiceAtTheErpAsync();
        var unrelated = await CreateInvoiceAsync();
        await CancelAsync(number);

        var first = Assert.Single(await ClaimOneAsync());

        Assert.Equal((number, OutboxKind.Cancel), (first.InvoiceNumber, first.Kind));
        Assert.Equal(OutboxStatus.Pending, await OutboxStatusAsync(unrelated, OutboxKind.Send));
    }

    [Fact]
    public async Task A_queued_invoice_with_a_cancellation_goes_before_the_unrelated_ones_and_its_cancellation_still_waits_for_it()
    {
        var unrelated = await CreateInvoiceAsync();
        var cancelled = await CreateInvoiceAsync();
        await CancelAsync(cancelled);

        var first = Assert.Single(await ClaimOneAsync());
        Assert.Equal((cancelled, OutboxKind.Send), (first.InvoiceNumber, first.Kind));

        // Its send entry is held: the next one out is the unrelated invoice, not the cancellation.
        var second = Assert.Single(await ClaimOneAsync());
        Assert.Equal((unrelated, OutboxKind.Send), (second.InvoiceNumber, second.Kind));
    }

    [Fact]
    public async Task Invoices_without_a_cancellation_keep_the_order_they_were_queued_in()
    {
        var older = await CreateInvoiceAsync();
        var newer = await CreateInvoiceAsync();

        Assert.Equal(older, Assert.Single(await ClaimOneAsync()).InvoiceNumber);
        Assert.Equal(newer, Assert.Single(await ClaimOneAsync()).InvoiceNumber);
    }

    private async Task<IReadOnlyList<ClaimedEntry>> ClaimOneAsync()
    {
        await using var scope = NewScope();
        var now = DateTimeOffset.UtcNow;
        return await scope.ServiceProvider.GetRequiredService<IOutboxStore>()
            .ClaimAsync(1, "A", now, now.AddSeconds(60), 10, CancellationToken.None);
    }

    [Fact]
    public async Task Two_workers_taking_at_the_same_moment_never_take_a_cancellation_whose_invoice_is_being_sent()
    {
        var numbers = new List<string>();
        for (var i = 0; i < 20; i++)
            numbers.Add(await CreateInvoiceAsync());
        foreach (var number in numbers)
            Assert.Equal(CancelStatus.Queued, await CancelAsync(number));

        // Both workers claim at the same moment, again and again, without sending: every invoice is held (Bekliyor) by
        // one of them, so no cancellation may come out.
        var now = DateTimeOffset.UtcNow;
        var taken = new List<ClaimedEntry>();
        for (var round = 0; round < 5; round++)
        {
            var both = await Task.WhenAll(Task.Run(() => ClaimAsync("A", now)), Task.Run(() => ClaimAsync("B", now)));
            taken.AddRange(both.SelectMany(t => t));
        }

        Assert.Equal(20, taken.Count);
        Assert.All(taken, e => Assert.Equal(OutboxKind.Send, e.Kind));
    }

    [Fact]
    public async Task A_cancellation_is_not_taken_while_the_invoice_is_held_by_a_worker_that_was_killed()
    {
        var number = await CreateInvoiceAsync();
        Assert.Equal(CancelStatus.Queued, await CancelAsync(number));

        // Worker A takes the invoice and dies before writing anything: the entry stays Bekliyor with A's lock.
        var now = DateTimeOffset.UtcNow;
        var send = Assert.Single(await ClaimAsync("A", now));
        Assert.Equal(OutboxKind.Send, send.Kind);

        // A's POST got to the ERP. After A's lock runs out the invoice is taken again, never its cancellation.
        Erp.KeepRecords = true;
        Erp.RecordInvoice(number);
        var later = now.AddSeconds(61);
        var again = Assert.Single(await ClaimAsync("B", later));
        Assert.Equal(OutboxKind.Send, again.Kind);

        await SendAsync(again, "B");
        var cancel = Assert.Single(await ClaimAsync("B", later));
        Assert.Equal(OutboxKind.Cancel, cancel.Kind);
    }

    [Fact]
    public async Task A_cancellation_sent_again_after_the_service_was_killed_mid_send_is_not_recorded_twice()
    {
        Erp.KeepRecords = true;
        var number = await CreateInvoiceAsync();
        await SendToErpAsync();
        Assert.Equal(CancelStatus.Queued, await CancelAsync(number));

        // Worker A sends the cancellation, the ERP records it, and A dies before writing the outcome.
        var now = DateTimeOffset.UtcNow;
        var first = Assert.Single(await ClaimAsync("A", now));
        await using (var scope = NewScope())
            await scope.ServiceProvider.GetRequiredService<IErpGateway>().CancelAsync(number, CancellationToken.None);

        // Once A's lock runs out, B takes it again: the ERP already has the cancellation, so it is not sent twice.
        var again = Assert.Single(await ClaimAsync("B", now.AddSeconds(61)));
        Assert.Equal(first.Id, again.Id);
        await SendAsync(again, "B");

        Assert.Equal(OutboxStatus.Completed, await OutboxStatusAsync(number, OutboxKind.Cancel));
        Assert.Equal(1, Erp.CancellationCount);
        Assert.Single(Erp.Requests, r => r == "CANCEL " + number);
    }

    [Fact]
    public async Task The_cancellation_of_a_failed_invoice_the_erp_does_not_have_sends_nothing_and_cancels_it()
    {
        Erp.KeepRecords = true;
        Erp.RefuseInvoices();
        var number = await CreateInvoiceAsync();
        await SendToErpAsync();
        Assert.Equal(InvoiceStatus.Failed, await InvoiceStatusAsync(number));
        Assert.Equal(CancelStatus.Queued, await CancelAsync(number));

        await SendToErpAsync();

        Assert.Equal(OutboxStatus.Completed, await OutboxStatusAsync(number, OutboxKind.Cancel));
        Assert.Equal(InvoiceStatus.Cancelled, await InvoiceStatusAsync(number));
        Assert.DoesNotContain(Erp.Requests, r => r.StartsWith("CANCEL"));
    }

    [Fact]
    public async Task The_cancellation_of_an_invoice_still_in_the_queue_sends_nothing_and_cancels_it()
    {
        Erp.KeepRecords = true;
        var number = await CreateInvoiceAsync();
        Assert.Equal(CancelStatus.Queued, await CancelAsync(number));

        await SendAllAsync();

        Assert.Empty(Erp.Requests);
        Assert.Equal(InvoiceStatus.Cancelled, await InvoiceStatusAsync(number));
        Assert.Equal(OutboxStatus.Failed, await OutboxStatusAsync(number, OutboxKind.Send));
        Assert.Equal(OutboxStatus.Completed, await OutboxStatusAsync(number, OutboxKind.Cancel));
    }

    [Fact]
    public async Task A_failed_cancellation_is_queued_again_recorded_and_completed()
    {
        var number = await InvoiceAtTheErpAsync();
        Assert.Equal(CancelStatus.Queued, await CancelAsync(number));
        await ExecuteAsync($"UPDATE erp_outbox SET status = 'Başarısız', attempt_count = 10, processed_at = now(), last_error = 'ERP kapalı' WHERE invoice_number = '{number}' AND kind = '{OutboxKind.Cancel}'");

        Assert.Equal(CancelStatus.Queued, await CancelAsync(number));

        Assert.Equal(OutboxStatus.Pending, await OutboxStatusAsync(number, OutboxKind.Cancel));
        Assert.Equal(2, await ScalarAsync<long>("SELECT count(*) FROM operator_actions WHERE invoice_number = @n", ("n", number)));
        var again = Assert.Single(await ClaimAsync("A", DateTimeOffset.UtcNow));
        Assert.Equal(1, again.Attempt);
        await SendAsync(again, "A");
        Assert.Equal(OutboxStatus.Completed, await OutboxStatusAsync(number, OutboxKind.Cancel));
        Assert.Equal(1, Erp.CancellationCount);
    }

    [Fact]
    public async Task A_waiting_or_completed_cancellation_is_not_queued_again()
    {
        var number = await InvoiceAtTheErpAsync();
        Assert.Equal(CancelStatus.Queued, await CancelAsync(number));
        Assert.Equal(CancelStatus.AlreadyRequested, await CancelAsync(number));

        await SendToErpAsync();

        Assert.Equal(CancelStatus.AlreadyRequested, await CancelAsync(number));
        Assert.Equal(OutboxStatus.Completed, await OutboxStatusAsync(number, OutboxKind.Cancel));
    }

    [Fact]
    public async Task The_cancelled_event_before_the_approval_and_twice_leaves_the_invoice_cancelled()
    {
        var number = await InvoiceAtTheErpAsync();
        var cancelled = ErpEvent("evt-cancel", WebhookEventType.Cancelled, number);

        Assert.Equal(WebhookEventStatus.Processed, (await DeliverAsync(cancelled)).Status);
        Assert.True((await DeliverAsync(cancelled)).Repeat);
        Assert.Equal(WebhookEventStatus.Ignored, (await DeliverAsync(ErpEvent("evt-cancel-2", WebhookEventType.Cancelled, number))).Status);
        Assert.Equal(WebhookEventStatus.Ignored, (await DeliverAsync(ErpEvent("evt-approved", WebhookEventType.Approved, number))).Status);

        Assert.Equal(InvoiceStatus.Cancelled, await InvoiceStatusAsync(number));
    }

    [Fact]
    public async Task An_approved_invoice_is_cancelled_by_the_event_and_a_rejected_one_is_not()
    {
        var approved = await InvoiceAtTheErpAsync();
        var rejected = await CreateInvoiceAsync();
        await SendToErpAsync();
        await DeliverAsync(ErpEvent("evt-1", WebhookEventType.Approved, approved));
        await DeliverAsync(ErpEvent("evt-2", WebhookEventType.Rejected, rejected));

        await DeliverAsync(ErpEvent("evt-3", WebhookEventType.Cancelled, approved));
        await DeliverAsync(ErpEvent("evt-4", WebhookEventType.Cancelled, rejected));

        Assert.Equal(InvoiceStatus.Cancelled, await InvoiceStatusAsync(approved));
        Assert.Equal(InvoiceStatus.Rejected, await InvoiceStatusAsync(rejected));
    }

    [Fact]
    public async Task A_cancelled_invoice_takes_no_new_cancellation_and_is_not_resent()
    {
        var number = await InvoiceAtTheErpAsync();
        await DeliverAsync(ErpEvent("evt-cancel", WebhookEventType.Cancelled, number));

        Assert.Equal(CancelStatus.AlreadyRequested, await CancelAsync(number));
        Assert.Equal(ResendStatus.NotFailed, await ResendAsync(number));
        Assert.Equal(InvoiceStatus.Cancelled, await InvoiceStatusAsync(number));
    }

    [Fact]
    public async Task The_cancelled_event_completes_a_failed_cancellation()
    {
        var number = await InvoiceAtTheErpAsync();
        Assert.Equal(CancelStatus.Queued, await CancelAsync(number));
        await ExecuteAsync($"UPDATE erp_outbox SET status = 'Başarısız', processed_at = now() WHERE invoice_number = '{number}' AND kind = '{OutboxKind.Cancel}'");

        await DeliverAsync(ErpEvent("evt-cancel", WebhookEventType.Cancelled, number));

        Assert.Equal(OutboxStatus.Completed, await OutboxStatusAsync(number, OutboxKind.Cancel));
        Assert.Equal(InvoiceStatus.Cancelled, await InvoiceStatusAsync(number));
    }

    [Fact]
    public async Task A_failed_invoice_at_the_erp_sends_only_the_cancellation_and_the_event_settles_everything()
    {
        Erp.KeepRecords = true;
        Erp.RefuseInvoices();
        var number = await CreateInvoiceAsync();
        await SendToErpAsync();
        Erp.RecordInvoice(number);
        Erp.Requests.Clear();
        await DeliverAsync(ErpEvent("evt-approved", WebhookEventType.Approved, number));
        Assert.Equal(CancelStatus.Queued, await CancelAsync(number));

        await SendAllAsync();
        Assert.Equal(["CANCEL " + number], Erp.Requests);
        Assert.Equal(InvoiceStatus.Failed, await InvoiceStatusAsync(number));

        await DeliverAsync(ErpEvent("evt-cancel", WebhookEventType.Cancelled, number));

        Assert.Equal(InvoiceStatus.Cancelled, await InvoiceStatusAsync(number));
        Assert.Equal($"ERP-{number}", await ScalarAsync<string>("SELECT erp_reference FROM invoices WHERE invoice_number = @n", ("n", number)));
        Assert.Null(await ScalarAsync<string>("SELECT last_error FROM invoices WHERE invoice_number = @n", ("n", number)));
        Assert.Equal(OutboxStatus.Completed, await OutboxStatusAsync(number, OutboxKind.Send));
        Assert.Equal(WebhookEventStatus.Ignored, await ScalarAsync<string>("SELECT status FROM erp_webhook_events WHERE event_id = 'evt-approved'"));
    }

    [Fact]
    public async Task A_second_cancellation_is_refused_and_a_cancelled_invoice_is_not_resent()
    {
        Erp.RefuseInvoices();
        var number = await CreateInvoiceAsync();
        await SendToErpAsync();
        Assert.Equal(CancelStatus.Queued, await CancelAsync(number));

        Assert.Equal(CancelStatus.AlreadyRequested, await CancelAsync(number));
        await using var scope = NewScope();
        var resend = await scope.ServiceProvider.GetRequiredService<ResendInvoiceHandler>().HandleAsync(number, Operator);
        Assert.Equal(ResendStatus.Cancelled, resend.Status);
        Assert.Equal(3, await ScalarAsync<long>(
            "SELECT count(*) FROM operator_actions WHERE invoice_number = @n", ("n", number)));
        Assert.Equal(1, await ScalarAsync<long>(
            "SELECT count(*) FROM erp_outbox WHERE invoice_number = @n AND kind = @k", ("n", number), ("k", OutboxKind.Cancel)));
    }

    [Fact]
    public async Task Reconciliation_cancels_an_invoice_the_erp_cancelled_and_completes_its_entries()
    {
        Erp.KeepRecords = true;
        Erp.RefuseInvoices();
        var number = await CreateInvoiceAsync();
        await SendToErpAsync();
        Erp.RecordInvoice(number);
        await DeliverAsync(ErpEvent("evt-approved", WebhookEventType.Approved, number));
        Assert.Equal(CancelStatus.Queued, await CancelAsync(number));
        var runId = await StartRunAsync();

        var done = await ApplyFixAsync(runId, new PlannedFinding(number, FindingType.CancelledInErp, "ERP'de iptal edilmiş",
            new Fix(FixKind.ApplyCancellation, number, InvoiceStatus.Failed, $"ERP-{number}")));

        Assert.True(done);
        Assert.Equal(InvoiceStatus.Cancelled, await InvoiceStatusAsync(number));
        Assert.Equal(OutboxStatus.Completed, await OutboxStatusAsync(number, OutboxKind.Cancel));
        Assert.Equal(OutboxStatus.Completed, await OutboxStatusAsync(number, OutboxKind.Send));
        Assert.Equal(WebhookEventStatus.Ignored, await ScalarAsync<string>("SELECT status FROM erp_webhook_events WHERE event_id = 'evt-approved'"));
        Assert.Equal($"ERP-{number}", await ScalarAsync<string>("SELECT erp_reference FROM invoices WHERE invoice_number = @n", ("n", number)));

        // The event that comes after the fix changes nothing.
        Assert.Equal(WebhookEventStatus.Ignored, (await DeliverAsync(ErpEvent("evt-late", WebhookEventType.Cancelled, number))).Status);
    }

    [Fact]
    public async Task Reconciliation_queues_again_a_cancellation_the_erp_does_not_have_and_only_once()
    {
        var number = await InvoiceAtTheErpAsync();
        await DeliverAsync(ErpEvent("evt-cancel", WebhookEventType.Cancelled, number));
        var runId = await StartRunAsync();
        var requeue = new PlannedFinding(number, FindingType.CancelledInService, "ERP'de iptal edilmemiş",
            new Fix(FixKind.RequeueCancellation, number, InvoiceStatus.Cancelled));

        Assert.True(await ApplyFixAsync(runId, requeue));
        Assert.False(await ApplyFixAsync(runId, requeue));

        await SendToErpAsync();
        Assert.Equal(1, Erp.CancellationCount);
        Assert.Equal(OutboxStatus.Completed, await OutboxStatusAsync(number, OutboxKind.Cancel));
        Assert.Equal(InvoiceStatus.Cancelled, await InvoiceStatusAsync(number));
    }

    [Fact]
    public async Task Of_the_final_invoices_older_than_the_window_reconciliation_reads_approved_and_cancelled_but_not_rejected()
    {
        var approved = await InvoiceAtTheErpAsync();
        var rejected = await CreateInvoiceAsync();
        var cancelled = await CreateInvoiceAsync();
        await SendToErpAsync();
        await DeliverAsync(ErpEvent("evt-1", WebhookEventType.Approved, approved));
        await DeliverAsync(ErpEvent("evt-2", WebhookEventType.Rejected, rejected));
        await DeliverAsync(ErpEvent("evt-3", WebhookEventType.Cancelled, cancelled));

        await using var scope = NewScope();
        var read = await scope.ServiceProvider.GetRequiredService<Application.Abstractions.IReconciliationStore>()
            .InvoicesToCheckAsync(DateTimeOffset.UtcNow.AddHours(1), DateTimeOffset.UtcNow.AddHours(-24), 1000, CancellationToken.None);

        Assert.Equal(new[] { approved, cancelled }.Order(), read.Select(i => i.InvoiceNumber).Order());
    }

    [Fact]
    public async Task A_cancellation_and_a_resend_arriving_together_send_nothing_and_cancel_the_invoice()
    {
        // Ten invoices the ERP refused (Başarısız) and does not have.
        Erp.KeepRecords = true;
        Erp.RefuseInvoices();
        var numbers = new List<string>();
        for (var i = 0; i < 10; i++)
            numbers.Add(await CreateInvoiceAsync());
        await SendAllAsync();
        Erp.AcceptInvoices();
        Erp.Requests.Clear();

        // For each invoice a cancellation and a resend arrive at the same moment, each in its own service copy.
        var outcomes = new List<(CancelStatus Cancel, ResendStatus Resend)>();
        foreach (var number in numbers)
        {
            var cancel = Task.Run(() => CancelAsync(number));
            var resend = Task.Run(() => ResendAsync(number));
            outcomes.Add((await cancel, await resend));
        }
        await SendAllAsync();

        // The cancellation is always queued. Whichever comes first, the ERP does not have the invoice: nothing goes to it.
        Assert.All(outcomes, o => Assert.Equal(CancelStatus.Queued, o.Cancel));
        Assert.Empty(Erp.Requests);
        foreach (var number in numbers)
            Assert.Equal(InvoiceStatus.Cancelled, await InvoiceStatusAsync(number));
    }
}
