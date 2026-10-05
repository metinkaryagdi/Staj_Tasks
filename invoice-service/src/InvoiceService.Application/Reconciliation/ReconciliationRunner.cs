using InvoiceService.Application.Abstractions;
using InvoiceService.Domain.Reconciliation;
using Microsoft.Extensions.DependencyInjection;
using Microsoft.Extensions.Options;

namespace InvoiceService.Application.Reconciliation;

/// <summary>The run cannot go on; the message is stored as the run's error. Nothing was changed yet when this is thrown.</summary>
public sealed class ReconciliationFailedException(string message) : Exception(message);

/// <summary>
/// One reconciliation run. It first reads both sides completely (the service's data, the ERP's list, the ERP's decisions)
/// and only then writes: if the ERP cannot be reached at any point of the reading, the run is Başarısız and no invoice
/// has been changed.
/// </summary>
public sealed class ReconciliationRunner(
    IReconciliationStore store, IErpGateway erp, IUnitOfWork unitOfWork, ReconciliationPlanner planner,
    IServiceScopeFactory scopes, IOptions<ReconciliationOptions> options, TimeProvider time,
    ILogger<ReconciliationRunner> logger)
{
    /// <summary>Does the run and records how it ended; never throws for a failed run.</summary>
    public async Task RunAsync(ReconciliationRun run, CancellationToken ct)
    {
        int checkedCount = 0, fixedCount = 0, reportedCount = 0;
        try
        {
            var plan = await PlanAsync(ct);
            checkedCount = plan.CheckedCount;

            var reported = plan.Findings.Where(f => f.Fix is null).ToList();
            foreach (var finding in reported)
                store.AddFinding(ToEntity(run.Id, finding));
            await unitOfWork.SaveChangesAsync(ct);
            reportedCount = reported.Count;

            foreach (var finding in plan.Findings.Where(f => f.Fix is not null))
            {
                ct.ThrowIfCancellationRequested();
                // A new scope for each fix: its own DbContext, so one invoice's change never lingers into the next.
                await using var scope = scopes.CreateAsyncScope();
                try
                {
                    if (await scope.ServiceProvider.GetRequiredService<FixApplier>().ApplyAsync(run.Id, finding))
                        fixedCount++;
                }
                catch (Exception ex) when (ex is not OperationCanceledException)
                {
                    // Its transaction is rolled back; the invoice stays as it was and the next run tries again. One failing
                    // fix (a deadlock victim, a lost connection) must not stop the fixes after it.
                    logger.LogWarning("Reconciliation fix skipped run={RunId} invoice={InvoiceNumber} type={FindingType}: {Message}",
                        run.Id, finding.InvoiceNumber, finding.FindingType, ex.Message);
                }
            }

            await store.FinishRunAsync(
                run.Id, ReconciliationStatus.Completed, checkedCount, fixedCount, reportedCount, null, time.GetUtcNow(), CancellationToken.None);
            logger.LogInformation(
                "Reconciliation run finished run={RunId} status={Status} checked={Checked} fixed={Fixed} reported={Reported}",
                run.Id, ReconciliationStatus.Completed, checkedCount, fixedCount, reportedCount);
        }
        catch (Exception ex)
        {
            var error = ex switch
            {
                ReconciliationFailedException => ex.Message,
                OperationCanceledException => "Servis durdu, çalışma yarıda kaldı.",
                _ => $"Beklenmeyen hata: {ex.Message}"
            };
            logger.LogWarning(
                "Reconciliation run failed run={RunId} checked={Checked} fixed={Fixed} reported={Reported} error={Error}",
                run.Id, checkedCount, fixedCount, reportedCount, error);
            await store.FinishRunAsync(
                run.Id, ReconciliationStatus.Failed, checkedCount, fixedCount, reportedCount, error, time.GetUtcNow(), CancellationToken.None);
        }
    }

    /// <summary>The reading half: nothing is written here.</summary>
    private async Task<ReconciliationPlan> PlanAsync(CancellationToken ct)
    {
        var now = time.GetUtcNow();
        var since = now - TimeSpan.FromHours(options.Value.LookbackHours);

        // The service's side is read before the ERP's, and the ERP's list runs up to a moment taken after that reading: an
        // invoice that is Gönderildi in the service's data was accepted by the ERP before then, so it is in the list.
        var invoices = (await store.InvoicesCreatedSinceAsync(since, ct)).ToList();
        var unknownEvents = await store.WaitingEventsOfUnknownInvoicesAsync(ct);

        var listed = await erp.ListAsync(since, time.GetUtcNow(), ct);
        if (!listed.Succeeded)
            throw new ReconciliationFailedException(listed.Error!);

        // An invoice created before the window can still be in the ERP's list (it was sent late): look it up too.
        var known = invoices.Select(i => i.InvoiceNumber).ToHashSet();
        var others = listed.Records.Select(r => r.InvoiceNumber).Where(n => !known.Contains(n)).Distinct().ToList();
        if (others.Count > 0)
            invoices.AddRange(await store.InvoicesByNumberAsync(others, ct));

        var snapshot = new ReconciliationSnapshot(now, invoices, listed.Records, unknownEvents);

        var decisions = new Dictionary<string, ErpDecision>();
        foreach (var number in planner.InvoicesToAsk(snapshot))
        {
            var found = await erp.FindAsync(number, ct);
            if (found.Lookup != ErpLookup.Found)
            {
                throw new ReconciliationFailedException(
                    $"{number} için ERP'den karar alınamadı: {found.Error ?? "ERP kaydı bulunamadı"}");
            }
            decisions[number] = found.Decision ?? ErpDecision.None;
        }

        return planner.Plan(snapshot, decisions);
    }

    private ReconciliationFinding ToEntity(long runId, PlannedFinding finding) => new()
    {
        RunId = runId, InvoiceNumber = finding.InvoiceNumber, FindingType = finding.FindingType,
        Action = FindingAction.Reported, Details = finding.Details, CreatedAt = time.GetUtcNow()
    };
}
