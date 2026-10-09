using InvoiceService.Application.Reconciliation;
using InvoiceService.Domain.Reconciliation;
using InvoiceService.IntegrationTests.Support;
using Microsoft.Extensions.DependencyInjection;

namespace InvoiceService.IntegrationTests;

/// <summary>That only one reconciliation run goes at a time, and that a run whose service died does not block the next.</summary>
public class ReconciliationLockTests(PostgresFixture postgres) : IntegrationTest(postgres)
{
    private async Task<StartedRun?> TryStartAsync(Task? startSignal = null)
    {
        await using var scope = NewScope();
        var service = scope.ServiceProvider.GetRequiredService<ReconciliationService>();
        if (startSignal is not null)
            await startSignal;
        return await service.TryStartAsync(operatorName: null, CancellationToken.None);
    }

    // Only the locks of this test's own database: pg_locks lists the locks of the whole server.
    private const string AdvisoryLocksOfThisDatabase =
        "locktype = 'advisory' AND granted AND database = (SELECT oid FROM pg_database WHERE datname = current_database())";

    private Task<long> AdvisoryLocksHeldAsync() =>
        ScalarAsync<long>($"SELECT count(*) FROM pg_locks WHERE {AdvisoryLocksOfThisDatabase}");

    // Scenario 5
    [Fact]
    public async Task Two_runs_asked_at_the_same_moment_start_only_one()
    {
        var start = new TaskCompletionSource();
        var first = TryStartAsync(start.Task);
        var second = TryStartAsync(start.Task);
        start.SetResult();
        var started = await Task.WhenAll(first, second);

        var winners = started.Where(s => s is not null).ToList();
        Assert.Single(winners);
        Assert.Equal(1L, await ScalarAsync<long>("SELECT count(*) FROM reconciliation_runs"));

        // Finished normally: the lock is let go and the next run can start.
        await winners[0]!.Lease.DisposeAsync();
        await Eventually.WaitUntilAsync(async () => await AdvisoryLocksHeldAsync() == 0, "the lock to be released");
        var next = await TryStartAsync();
        Assert.NotNull(next);
        await next.Lease.DisposeAsync();
    }

    [Fact]
    public async Task When_the_copy_holding_the_lock_dies_the_lock_falls_and_the_next_run_can_start()
    {
        var crashed = await TryStartAsync();
        Assert.NotNull(crashed);
        Assert.Null(await TryStartAsync());

        // The copy "dies": the server ends the connection the lock lives on, without the copy letting go of it.
        await using (var connection = await OpenConnectionAsync())
        {
            await using var kill = new Npgsql.NpgsqlCommand(
                $"SELECT pg_terminate_backend(pid) FROM pg_locks WHERE {AdvisoryLocksOfThisDatabase}", connection);
            await kill.ExecuteNonQueryAsync();
        }
        await Eventually.WaitUntilAsync(async () => await AdvisoryLocksHeldAsync() == 0, "the dead copy's lock to fall");

        var next = await TryStartAsync();

        Assert.NotNull(next);
        // The run the dead copy left Çalışıyor is closed by the next one.
        Assert.Equal(ReconciliationStatus.Failed,
            await ScalarAsync<string>("SELECT status FROM reconciliation_runs WHERE id = @id", ("id", crashed.Run.Id)));
        Assert.Equal(ReconciliationStatus.Running,
            await ScalarAsync<string>("SELECT status FROM reconciliation_runs WHERE id = @id", ("id", next.Run.Id)));
        await next.Lease.DisposeAsync();
    }
}
