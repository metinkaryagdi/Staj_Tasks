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
    private async Task TakeTurnsAsync(int turns, Task startSignal)
    {
        await using var scope = NewScope();
        var pacer = scope.ServiceProvider.GetRequiredService<IErpSendPacer>();
        await startSignal;
        for (var i = 0; i < turns; i++)
            await pacer.WaitForTurnAsync(CancellationToken.None);
    }

    // Scenario 8
    [Fact]
    public async Task Two_copies_taking_100_turns_at_the_same_time_never_get_turns_closer_than_the_set_interval()
    {
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
        var watch = Stopwatch.StartNew();
        start.SetResult();
        await Task.WhenAll(first, second);
        watch.Stop();

        // A turn is the logged value minus one interval, so two turns are as far apart as two logged values.
        Assert.Equal(100L, await ScalarAsync<long>("SELECT count(*) FROM pace_log"));
        var tooClose = await ScalarAsync<long>("""
            SELECT count(*) FROM (
                SELECT next_turn_at - lag(next_turn_at) OVER (ORDER BY next_turn_at) AS gap FROM pace_log
            ) g WHERE g.gap < make_interval(secs => @spacing)
            """, ("spacing", spacing));
        Assert.Equal(0L, tooClose);

        // And the copies really waited for their turns (99 intervals between the first and the last).
        Assert.True(watch.Elapsed >= TimeSpan.FromSeconds(99 * spacing) - TimeSpan.FromMilliseconds(100),
            $"100 turns took only {watch.Elapsed.TotalSeconds:0.00} s");
    }
}
