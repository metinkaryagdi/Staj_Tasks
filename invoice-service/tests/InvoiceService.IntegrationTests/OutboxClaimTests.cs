using System.Diagnostics;
using InvoiceService.Application.Abstractions;
using InvoiceService.Application.Outbox;
using InvoiceService.Domain.Invoices;
using InvoiceService.Domain.Outbox;
using InvoiceService.IntegrationTests.Support;
using Microsoft.AspNetCore.Http;
using Microsoft.Extensions.DependencyInjection;

namespace InvoiceService.IntegrationTests;

/// <summary>Who may take an outbox entry, and whose result counts: the database decides, so these run against it.</summary>
public class OutboxClaimTests(PostgresFixture postgres) : IntegrationTest(postgres)
{
    private const string Number = "FTR-000001";

    private async Task<IReadOnlyList<ClaimedEntry>> ClaimAsync(string workerId, int limit, Task startSignal)
    {
        await using var scope = NewScope();
        var processor = scope.ServiceProvider.GetRequiredService<OutboxProcessor>();
        await startSignal;
        return await processor.ClaimAsync(limit, workerId, CancellationToken.None);
    }

    [Fact]
    public async Task The_claim_hands_over_the_invoice_s_trace_and_due_time_and_a_resend_keeps_the_trace()
    {
        string traceParent;
        using (var request = new Activity("POST /api/v1/invoices").SetIdFormat(ActivityIdFormat.W3C).Start())
        {
            await CreateInvoiceAsync();
            traceParent = request.Id!;
        }
        var dueAt = await ScalarAsync<DateTime>($"SELECT next_attempt_at FROM erp_outbox WHERE invoice_number = '{Number}'");

        var claimed = Assert.Single(await ClaimAsync("A", 10, Task.CompletedTask));

        Assert.Equal(traceParent, claimed.TraceParent);
        Assert.Equal(dueAt, claimed.DueAt.UtcDateTime);

        // A resend queues the entry again in the same trace: the journey stays one trace.
        await using var scope = NewScope();
        await scope.ServiceProvider.GetRequiredService<IOutboxStore>().ResetAsync(Number, DateTimeOffset.UtcNow, CancellationToken.None);
        Assert.Equal(traceParent, await ScalarAsync<string>($"SELECT trace_parent FROM erp_outbox WHERE invoice_number = '{Number}'"));
    }

    [Fact]
    public async Task Two_workers_taking_at_the_same_moment_never_take_the_same_entry()
    {
        const int entries = 60;
        for (var i = 0; i < entries; i++)
            await CreateInvoiceAsync();

        var taken = new List<(string Worker, long Id)>();
        // 60 entries are gone after two rounds; the limit only stops a broken claim that keeps handing out the same entries.
        for (var round = 0; round < 10; round++)
        {
            // Both claims are prepared first and released together, so they really overlap.
            var start = new TaskCompletionSource();
            var a = ClaimAsync("A", 15, start.Task);
            var b = ClaimAsync("B", 15, start.Task);
            start.SetResult();
            var claimed = await Task.WhenAll(a, b);

            if (claimed.All(r => r.Count == 0))
                break;
            taken.AddRange(claimed[0].Select(e => ("A", e.Id)));
            taken.AddRange(claimed[1].Select(e => ("B", e.Id)));
        }

        Assert.Equal(entries, taken.Count);
        Assert.Equal(entries, taken.Select(t => t.Id).Distinct().Count());
        // Each entry was counted as one attempt, by whoever took it.
        Assert.Equal(0L, await ScalarAsync<long>("SELECT count(*) FROM erp_outbox WHERE attempt_count <> 1"));
    }

    [Fact]
    public async Task Entries_whose_time_has_come_are_taken_in_the_order_they_entered_the_queue_not_the_order_their_time_came()
    {
        for (var i = 0; i < 4; i++)
            await CreateInvoiceAsync();
        // FTR-000001 entered the queue an hour ago and is a retry whose wait ended a second ago. FTR-000002 and -000003 entered
        // later and have been due for minutes. FTR-000004 entered first of all, but its retry is a minute away.
        await ExecuteAsync("""
            UPDATE erp_outbox SET attempt_count = 1, created_at = now() - interval '1 hour', next_attempt_at = now() - interval '1 second' WHERE invoice_number = 'FTR-000001';
            UPDATE erp_outbox SET created_at = now() - interval '10 minutes', next_attempt_at = now() - interval '10 minutes' WHERE invoice_number = 'FTR-000002';
            UPDATE erp_outbox SET created_at = now() - interval '9 minutes', next_attempt_at = now() - interval '9 minutes' WHERE invoice_number = 'FTR-000003';
            UPDATE erp_outbox SET attempt_count = 1, created_at = now() - interval '2 hours', next_attempt_at = now() + interval '1 minute' WHERE invoice_number = 'FTR-000004';
            """);

        await using var scope = NewScope();
        var outbox = scope.ServiceProvider.GetRequiredService<IOutboxStore>();
        var taken = new List<string>();
        for (var i = 0; i < 4; i++)
        {
            var now = DateTimeOffset.UtcNow;
            taken.AddRange((await outbox.ClaimAsync(1, "A", now, now.AddSeconds(60), 10, CancellationToken.None)).Select(e => e.InvoiceNumber));
        }

        Assert.Equal(["FTR-000001", "FTR-000002", "FTR-000003"], taken);
    }

    [Fact]
    public async Task Invoices_that_keep_failing_do_not_hold_back_a_new_invoice()
    {
        // 12 invoices the ERP answers with 500 every time, then a new one. A worker takes 10 entries at a time.
        const int failing = 12;
        for (var i = 0; i < failing; i++)
            await CreateInvoiceAsync();
        var fresh = await CreateInvoiceAsync();
        Erp.OnPost = number => number == fresh
            ? Results.Json(new { erpReference = $"ERP-{number}" }, statusCode: 202)
            : Results.Problem(statusCode: 500, title: "ERP hatası");

        await using var scope = NewScope();
        var processor = scope.ServiceProvider.GetRequiredService<OutboxProcessor>();
        // Round 1 takes the 10 oldest and all of them fail. Their retry is seconds away, so round 2 takes the 2 never tried
        // and the new invoice, which entered the queue last.
        for (var round = 0; round < 2; round++)
            foreach (var entry in await processor.ClaimAsync(10, "A", CancellationToken.None))
                await processor.SendAsync(entry, "A");

        Assert.Equal(InvoiceStatus.Sent, await ScalarAsync<string>("SELECT status FROM invoices WHERE invoice_number = @n", ("n", fresh)));
    }

    /// <summary>Worker A takes the entry; its time runs out; worker B takes it.</summary>
    private async Task<(ClaimedEntry A, ClaimedEntry B)> TakenOverAsync()
    {
        await CreateInvoiceAsync();
        await using var scope = NewScope();
        var outbox = scope.ServiceProvider.GetRequiredService<IOutboxStore>();

        var now = DateTimeOffset.UtcNow;
        var a = (await outbox.ClaimAsync(1, "A", now, now.AddSeconds(60), 10, CancellationToken.None)).Single();
        var later = now.AddSeconds(61);
        var b = (await outbox.ClaimAsync(1, "B", later, later.AddSeconds(60), 10, CancellationToken.None)).Single();

        Assert.NotEqual(a.ClaimToken, b.ClaimToken);
        return (a, b);
    }

    private async Task<bool> WriteLateFailureAsync(ClaimedEntry entry)
    {
        await using var scope = NewScope();
        var outcomes = scope.ServiceProvider.GetRequiredService<OutboxOutcomeWriter>();
        var failed = new ErpSendResult(false, null, 500, "geç gelen hata", TimeSpan.Zero);
        return await outcomes.WriteAsync(
            entry, new RetryDecision(SendOutcome.Failed, TimeSpan.Zero, "geç gelen sonuç"), failed, DateTimeOffset.UtcNow);
    }

    [Fact]
    public async Task A_late_result_of_the_old_worker_does_not_overwrite_the_result_of_the_new_one()
    {
        var (a, b) = await TakenOverAsync();

        await using (var scope = NewScope())
            await scope.ServiceProvider.GetRequiredService<OutboxProcessor>().SendAsync(b, "B");
        Assert.Equal(InvoiceStatus.Sent, await ScalarAsync<string>("SELECT status FROM invoices WHERE invoice_number = @n", ("n", Number)));

        var written = await WriteLateFailureAsync(a);

        Assert.False(written);
        Assert.Equal(InvoiceStatus.Sent, await ScalarAsync<string>("SELECT status FROM invoices WHERE invoice_number = @n", ("n", Number)));
        Assert.Equal($"ERP-{Number}", await ScalarAsync<string>("SELECT erp_reference FROM invoices WHERE invoice_number = @n", ("n", Number)));
        Assert.Null(await ScalarAsync<string>("SELECT last_error FROM invoices WHERE invoice_number = @n", ("n", Number)));
        Assert.Equal(OutboxStatus.Completed, await ScalarAsync<string>("SELECT status FROM erp_outbox WHERE invoice_number = @n", ("n", Number)));
    }

    [Fact]
    public async Task A_late_result_of_the_old_worker_does_not_touch_an_entry_the_new_worker_still_holds()
    {
        var (a, b) = await TakenOverAsync();

        var written = await WriteLateFailureAsync(a);

        Assert.False(written);
        Assert.Equal(OutboxStatus.Pending, await ScalarAsync<string>("SELECT status FROM erp_outbox WHERE invoice_number = @n", ("n", Number)));
        Assert.Equal(b.ClaimToken, await ScalarAsync<Guid>("SELECT claim_token FROM erp_outbox WHERE invoice_number = @n", ("n", Number)));
        Assert.Equal(InvoiceStatus.Pending, await ScalarAsync<string>("SELECT status FROM invoices WHERE invoice_number = @n", ("n", Number)));
    }
}
