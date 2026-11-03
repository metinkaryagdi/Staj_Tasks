using InvoiceService.Application.Abstractions;
using InvoiceService.Application.Invoices;
using InvoiceService.Application.Outbox;
using InvoiceService.Domain.Operators;
using InvoiceService.Domain.Outbox;
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

    [Fact]
    public async Task A_cancellation_waits_while_the_invoice_waits_for_a_retry_and_goes_after_it_reaches_the_erp()
    {
        Erp.KeepRecords = true;
        var number = await CreateInvoiceAsync();
        Erp.OnPost = _ => Results.Problem(statusCode: 500, title: "ERP hatası");
        await SendToErpAsync();
        Assert.Equal(OutboxStatus.Pending, await OutboxStatusAsync(number, OutboxKind.Send));

        Assert.Equal(CancelStatus.Queued, await CancelAsync(number));

        // The invoice's retry is not due yet; the cancellation is due now but is not taken.
        Assert.Empty(await ClaimAsync("A", DateTimeOffset.UtcNow));
        Assert.Equal(["POST " + number], Erp.Requests);

        // The retry gets the invoice to the ERP; only then is the cancellation taken and sent.
        Erp.AcceptInvoices();
        var retry = Assert.Single(await ClaimAsync("A", DateTimeOffset.UtcNow.AddMinutes(10)));
        Assert.Equal(OutboxKind.Send, retry.Kind);
        await SendAsync(retry, "A");
        var cancel = Assert.Single(await ClaimAsync("A", DateTimeOffset.UtcNow.AddMinutes(10)));
        Assert.Equal(OutboxKind.Cancel, cancel.Kind);
        await SendAsync(cancel, "A");

        Assert.Equal(["POST " + number, "POST " + number, "CANCEL " + number], Erp.Requests);
        Assert.Equal(OutboxStatus.Completed, await OutboxStatusAsync(number, OutboxKind.Cancel));
        Assert.Equal(1, Erp.CancellationCount);
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

        // After A's lock runs out the invoice is taken again, never its cancellation.
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
    public async Task The_cancellation_of_an_invoice_the_erp_does_not_have_is_not_sent_and_fails()
    {
        Erp.KeepRecords = true;
        Erp.RefuseInvoices();
        var number = await CreateInvoiceAsync();
        await SendToErpAsync();
        Assert.Equal(CancelStatus.Queued, await CancelAsync(number));

        await SendToErpAsync();

        Assert.Equal(OutboxStatus.Failed, await OutboxStatusAsync(number, OutboxKind.Cancel));
        Assert.DoesNotContain(Erp.Requests, r => r.StartsWith("CANCEL"));
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
    public async Task A_cancellation_and_a_resend_arriving_together_leave_no_invoice_at_the_erp_without_its_cancellation()
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

        // The cancellation is always queued. The resend either loses (refused: the invoice is never sent, nor is the
        // cancellation of an invoice the ERP does not have) or wins (the invoice goes first, its cancellation after it).
        Assert.All(outcomes, o => Assert.Equal(CancelStatus.Queued, o.Cancel));
        foreach (var (number, outcome) in numbers.Zip(outcomes))
        {
            var postAt = Erp.Requests.IndexOf("POST " + number);
            var cancelAt = Erp.Requests.IndexOf("CANCEL " + number);
            var requests = $"{number} resend={outcome.Resend}: {string.Join(", ", Erp.Requests)}";
            if (outcome.Resend == ResendStatus.Queued)
                Assert.True(postAt >= 0 && cancelAt > postAt, requests);
            else
                Assert.True(outcome.Resend == ResendStatus.Cancelled && postAt < 0 && cancelAt < 0, requests);
        }
    }
}
