using InvoiceService.Application.Tests.Fakes;
using InvoiceService.Domain.Reconciliation;

namespace InvoiceService.Application.Tests;

/// <summary>Starting a run takes the lock, so only one goes at a time.</summary>
public class ReconciliationServiceTests
{
    private readonly Scenario _s = new();

    [Fact]
    public async Task Starting_takes_the_lock_and_records_a_running_run()
    {
        var started = await _s.ReconciliationService().TryStartAsync(CancellationToken.None);

        Assert.NotNull(started);
        Assert.Equal(ReconciliationStatus.Running, started.Run.Status);
        Assert.Null(started.Run.FinishedAt);
        Assert.Equal(1, _s.Lock.Acquired);
        Assert.Equal(0, _s.Lock.Released);
    }

    [Fact]
    public async Task While_the_lock_is_held_by_another_run_nothing_starts()
    {
        _s.Lock.HeldByOthers = true;

        var started = await _s.ReconciliationService().TryStartAsync(CancellationToken.None);

        Assert.Null(started);
        Assert.Empty(_s.Reconciliation.Runs);
    }

    [Fact]
    public async Task A_second_start_while_the_first_still_holds_the_lock_gets_nothing_then_succeeds_after_it_is_released()
    {
        var service = _s.ReconciliationService();
        var first = await service.TryStartAsync(CancellationToken.None);
        _s.Lock.HeldByOthers = true; // what the database says once the first holds the advisory lock

        var second = await service.TryStartAsync(CancellationToken.None);
        await service.ExecuteAsync(first!, CancellationToken.None);
        _s.Lock.HeldByOthers = false;
        var third = await service.TryStartAsync(CancellationToken.None);

        Assert.Null(second);
        Assert.NotNull(third);
        Assert.Equal(1, _s.Lock.Released);
    }

    [Fact]
    public async Task Executing_closes_the_run_and_lets_the_lock_go()
    {
        var service = _s.ReconciliationService();
        var started = await service.TryStartAsync(CancellationToken.None);

        await service.ExecuteAsync(started!, CancellationToken.None);

        Assert.Equal(ReconciliationStatus.Completed, started!.Run.Status);
        Assert.Equal(1, _s.Lock.Released);
    }

    [Fact]
    public async Task A_run_left_running_by_a_stopped_service_is_marked_failed_when_the_next_one_starts()
    {
        _s.Reconciliation.Runs.Add(new ReconciliationRun { Id = 1, StartedAt = Scenario.Start.AddMinutes(-30), Status = ReconciliationStatus.Running });

        var started = await _s.ReconciliationService().TryStartAsync(CancellationToken.None);

        var abandoned = _s.Reconciliation.Runs.Single(r => r.Id == 1);
        Assert.Equal(ReconciliationStatus.Failed, abandoned.Status);
        Assert.Contains("Servis durdu", abandoned.Error);
        Assert.Equal(ReconciliationStatus.Running, started!.Run.Status);
    }

    [Fact]
    public async Task If_the_run_cannot_be_recorded_the_lock_is_let_go()
    {
        _s.Reconciliation.FailToStart = true;

        await Assert.ThrowsAsync<InvalidOperationException>(() => _s.ReconciliationService().TryStartAsync(CancellationToken.None));

        Assert.Equal(1, _s.Lock.Acquired);
        Assert.Equal(1, _s.Lock.Released);
    }
}
