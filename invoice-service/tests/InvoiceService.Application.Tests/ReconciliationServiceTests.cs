using InvoiceService.Application.Tests.Fakes;
using InvoiceService.Domain.Operators;
using InvoiceService.Domain.Reconciliation;

namespace InvoiceService.Application.Tests;

/// <summary>Starting a run takes the lock, so only one goes at a time.</summary>
public class ReconciliationServiceTests
{
    private readonly Scenario _s = new();

    [Fact]
    public async Task Starting_takes_the_lock_and_records_a_running_run()
    {
        var started = await _s.ReconciliationService().TryStartAsync(null, CancellationToken.None);

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

        var started = await _s.ReconciliationService().TryStartAsync(null, CancellationToken.None);

        Assert.Null(started);
        Assert.Empty(_s.Reconciliation.Runs);
    }

    [Fact]
    public async Task A_second_start_while_the_first_still_holds_the_lock_gets_nothing_then_succeeds_after_it_is_released()
    {
        var service = _s.ReconciliationService();
        var first = await service.TryStartAsync(null, CancellationToken.None);
        _s.Lock.HeldByOthers = true; // what the database says once the first holds the advisory lock

        var second = await service.TryStartAsync(null, CancellationToken.None);
        await service.ExecuteAsync(first!, CancellationToken.None);
        _s.Lock.HeldByOthers = false;
        var third = await service.TryStartAsync(null, CancellationToken.None);

        Assert.Null(second);
        Assert.NotNull(third);
        Assert.Equal(1, _s.Lock.Released);
    }

    [Fact]
    public async Task Executing_closes_the_run_and_lets_the_lock_go()
    {
        var service = _s.ReconciliationService();
        var started = await service.TryStartAsync(null, CancellationToken.None);

        await service.ExecuteAsync(started!, CancellationToken.None);

        Assert.Equal(ReconciliationStatus.Completed, started!.Run.Status);
        Assert.Equal(1, _s.Lock.Released);
    }

    [Fact]
    public async Task A_run_left_running_by_a_stopped_service_is_marked_failed_when_the_next_one_starts()
    {
        _s.Reconciliation.Runs.Add(new ReconciliationRun { Id = 1, StartedAt = Scenario.Start.AddMinutes(-30), Status = ReconciliationStatus.Running });

        var started = await _s.ReconciliationService().TryStartAsync(null, CancellationToken.None);

        var abandoned = _s.Reconciliation.Runs.Single(r => r.Id == 1);
        Assert.Equal(ReconciliationStatus.Failed, abandoned.Status);
        Assert.Contains("Servis durdu", abandoned.Error);
        Assert.Equal(ReconciliationStatus.Running, started!.Run.Status);
    }

    [Fact]
    public async Task If_the_run_cannot_be_recorded_the_lock_is_let_go()
    {
        _s.Reconciliation.FailToStart = true;

        await Assert.ThrowsAsync<InvalidOperationException>(() => _s.ReconciliationService().TryStartAsync(null, CancellationToken.None));

        Assert.Equal(1, _s.Lock.Acquired);
        Assert.Equal(1, _s.Lock.Released);
    }

    [Fact]
    public async Task A_run_started_by_an_operator_keeps_the_name_and_the_request_is_recorded_with_the_run()
    {
        var started = await _s.ReconciliationService().TryStartAsync("Ayşe Yılmaz", CancellationToken.None);

        Assert.Equal("Ayşe Yılmaz", started!.Run.StartedBy);
        var action = Assert.Single(_s.OperatorActions.Actions);
        Assert.Equal(("Ayşe Yılmaz", OperatorActionType.StartReconciliation, null, $"Başlatıldı: çalışma {started.Run.Id}"),
            (action.OperatorName, action.Action, action.InvoiceNumber, action.Result));
        Assert.Equal(1, _s.UnitOfWork.Committed);
    }

    [Fact]
    public async Task A_start_refused_because_a_run_is_going_is_recorded_for_an_operator_but_not_for_the_schedule()
    {
        _s.Lock.HeldByOthers = true;

        Assert.Null(await _s.ReconciliationService().TryStartAsync(null, CancellationToken.None));
        Assert.Empty(_s.OperatorActions.Actions);

        Assert.Null(await _s.ReconciliationService().TryStartAsync("Ayşe", CancellationToken.None));
        var action = Assert.Single(_s.OperatorActions.Actions);
        Assert.Equal(OperatorActionResult.AlreadyRunning, action.Result);
        Assert.Empty(_s.Reconciliation.Runs);
    }

    [Fact]
    public async Task A_run_the_schedule_starts_is_marked_as_the_schedule_and_has_no_record()
    {
        var started = await _s.ReconciliationService().TryStartAsync(null, CancellationToken.None);

        Assert.Equal(ReconciliationRun.Schedule, started!.Run.StartedBy);
        Assert.Empty(_s.OperatorActions.Actions);
    }
}
