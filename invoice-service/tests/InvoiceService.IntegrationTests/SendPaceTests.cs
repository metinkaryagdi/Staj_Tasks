using System.Diagnostics;
using InvoiceService.Application.Abstractions;
using InvoiceService.Application.Outbox;
using InvoiceService.IntegrationTests.Support;
using Microsoft.Extensions.DependencyInjection;
using Microsoft.Extensions.Options;

namespace InvoiceService.IntegrationTests;

/// <summary>The send rate that all service copies share (one row in erp_send_pace).</summary>
public class SendPaceTests(PostgresFixture postgres) : IntegrationTest(postgres)
{
    /// <summary>Takes the turns one after the other; returns the moment each send would start (when the wait is over).</summary>
    private async Task<long[]> TakeTurnsAsync(int turns, Task startSignal)
    {
        await using var scope = NewScope();
        var pacer = scope.ServiceProvider.GetRequiredService<IErpSendPacer>();
        await startSignal;
        var started = new long[turns];
        for (var i = 0; i < turns; i++)
        {
            await pacer.WaitForTurnAsync(CancellationToken.None);
            started[i] = Stopwatch.GetTimestamp();
        }
        return started;
    }

    [Fact]
    public Task Two_copies_taking_100_turns_at_the_same_time_start_their_sends_the_set_interval_apart() =>
        AssertTurnsAndSendsAreSpacedAsync(idleBefore: false);

    [Fact]
    public Task Two_copies_taking_100_turns_at_the_same_time_after_a_minute_without_sends_start_their_sends_the_set_interval_apart() =>
        AssertTurnsAndSendsAreSpacedAsync(idleBefore: true);

    private async Task AssertTurnsAndSendsAreSpacedAsync(bool idleBefore)
    {
        // Where the shared turn stands when the copies start: free right now, or free since a minute (the service was
        // idle). Set before the log below exists, so it is not logged.
        await ExecuteAsync($"UPDATE erp_send_pace SET next_turn_at = now() - interval '{(idleBefore ? "1 minute" : "0 seconds")}'");

        // Every update of the shared row is logged by the database itself with the turn it handed out, so the turns can
        // be compared exactly instead of by when the copies happened to wake up.
        await ExecuteAsync("""
            CREATE TABLE pace_log (id bigserial PRIMARY KEY, next_turn_at timestamptz NOT NULL);
            CREATE FUNCTION log_pace() RETURNS trigger AS $$
            BEGIN
                INSERT INTO pace_log (next_turn_at) VALUES (NEW.next_turn_at);
                RETURN NEW;
            END $$ LANGUAGE plpgsql;
            CREATE TRIGGER log_pace AFTER UPDATE ON erp_send_pace FOR EACH ROW EXECUTE FUNCTION log_pace();
            """);
        double spacing;
        await using (var scope = NewScope())
            spacing = 1.0 / scope.ServiceProvider.GetRequiredService<IOptions<OutboxOptions>>().Value.SendsPerSecond;

        var start = new TaskCompletionSource();
        var first = TakeTurnsAsync(50, start.Task);
        var second = TakeTurnsAsync(50, start.Task);
        start.SetResult();
        var started = (await Task.WhenAll(first, second)).SelectMany(s => s).Order().ToArray();

        // The turns are only handed out in the database; the sends must also start that far apart. 100 sends take at
        // least 99 intervals from the first to the last. The margin covers the first send waking up late (that only
        // shortens the measured time; a slow machine makes it longer). Without waiting they start within some ms.
        var spent = Stopwatch.GetElapsedTime(started[0], started[^1]);
        var least = TimeSpan.FromSeconds(99 * spacing) - TimeSpan.FromMilliseconds(250);
        Assert.True(spent >= least, $"100 sends started within {spent.TotalMilliseconds:0} ms; at least {least.TotalMilliseconds:0} ms expected.");

        // A turn is the logged value minus one interval, so two turns are as far apart as two logged values.
        Assert.Equal(100L, await ScalarAsync<long>("SELECT count(*) FROM pace_log"));
        var tooClose = await ScalarAsync<long>("""
            SELECT count(*) FROM (
                SELECT next_turn_at - lag(next_turn_at) OVER (ORDER BY next_turn_at) AS gap FROM pace_log
            ) g WHERE g.gap < make_interval(secs => @spacing)
            """, ("spacing", spacing));
        Assert.Equal(0L, tooClose);
    }
}
