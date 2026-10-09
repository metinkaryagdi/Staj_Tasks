using InvoiceService.Application.Abstractions;
using InvoiceService.Application.Outbox;
using InvoiceService.Domain.Invoices;
using InvoiceService.Domain.Outbox;
using InvoiceService.IntegrationTests.Support;
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

    // Scenario 1
    [Fact]
    public async Task Two_workers_taking_at_the_same_moment_never_take_the_same_entry()
    {
        const int entries = 60;
        for (var i = 0; i < entries; i++)
            await CreateInvoiceAsync();

        var taken = new List<(string Worker, long Id)>();
        while (true)
        {
            // Both claims are prepared first and released together, so they really overlap.
            var start = new TaskCompletionSource();
            var a = ClaimAsync("A", 15, start.Task);
            var b = ClaimAsync("B", 15, start.Task);
            start.SetResult();
            var round = await Task.WhenAll(a, b);

            if (round.All(r => r.Count == 0))
                break;
            taken.AddRange(round[0].Select(e => ("A", e.Id)));
            taken.AddRange(round[1].Select(e => ("B", e.Id)));
        }

        Assert.Equal(entries, taken.Count);
        Assert.Equal(entries, taken.Select(t => t.Id).Distinct().Count());
        // Each entry was counted as one attempt, by whoever took it.
        Assert.Equal(0L, await ScalarAsync<long>("SELECT count(*) FROM erp_outbox WHERE attempt_count <> 1"));
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

    // Scenario 2
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
