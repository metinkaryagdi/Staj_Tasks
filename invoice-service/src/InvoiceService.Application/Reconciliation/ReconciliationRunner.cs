using InvoiceService.Application.Abstractions;
using InvoiceService.Domain.Invoices;
using InvoiceService.Domain.Reconciliation;
using Microsoft.Extensions.DependencyInjection;
using Microsoft.Extensions.Options;

namespace InvoiceService.Application.Reconciliation;

/// <summary>
/// The run cannot go on; the message is stored as the run's error. Nothing was changed yet when this is thrown.
/// </summary>
public sealed class ReconciliationFailedException(string message) : Exception(message);

/// <summary>
/// One reconciliation run. It first reads both sides completely (the service's data, the ERP's list, the ERP's
/// decisions) and only then writes: if the ERP cannot be reached at any point of the reading, the run is Başarısız
/// and no invoice has been changed.
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
            var (plan, checks) = await PlanAsync(run.Id, ct);
            checkedCount = plan.CheckedCount;

            // Before the fixes: a fix moves updated_at past this time, so an answer is never taken for a newer state.
            await store.RecordErpChecksAsync(checks, time.GetUtcNow(), ct);

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
                    // Its transaction is rolled back; the invoice stays as it was and the next run tries again. One
                    // failing fix (a deadlock victim, a lost connection) must not stop the fixes after it. The innermost
                    // exception carries the reason (an EF exception only says to look at it).
                    var reason = ex.GetBaseException().Message;
                    logger.LogWarning("Reconciliation fix skipped run={RunId} invoice={InvoiceNumber} type={FindingType}: {Message}",
                        run.Id, finding.InvoiceNumber, finding.FindingType, reason);
                    if (await ReportUnfixedAsync(run.Id, finding, reason))
                        reportedCount++;
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

    /// <summary>The reading half: nothing is written here. Also returns every answer the ERP gave about an
    /// invoice.</summary>
    private async Task<(ReconciliationPlan Plan, List<ErpCheck> Checks)> PlanAsync(long runId, CancellationToken ct)
    {
        var now = time.GetUtcNow();
        var since = now - TimeSpan.FromHours(options.Value.LookbackHours);

        // The service's side is read before the ERP's, and the ERP's list runs up to a moment taken after that
        // reading: an invoice that is Gönderildi in the service's data was accepted by the ERP before then, so it is
        // in the list.
        var invoices = (await store.InvoicesToCheckAsync(since, ct)).ToList();
        var unknownEvents = await store.WaitingEventsOfUnknownInvoicesAsync(ct);

        var listed = await erp.ListAsync(since, time.GetUtcNow(), ct);
        if (!listed.Succeeded)
            throw new ReconciliationFailedException(listed.Error!);

        // An invoice created before the window can still be in the ERP's list (it was sent late): look it up too.
        var known = invoices.Select(i => i.InvoiceNumber).ToHashSet();
        var others = listed.Records.Select(r => r.InvoiceNumber).Where(n => !known.Contains(n)).Distinct().ToList();
        if (others.Count > 0)
            invoices.AddRange(await store.InvoicesByNumberAsync(others, ct));

        var records = listed.Records.ToList();
        var decisions = new Dictionary<string, ErpDecision>();
        var checks = new List<ErpCheck>();
        var skipped = 0;

        // An unsettled invoice older than the window is not in the ERP's list: ask the ERP for it, so a long outage of
        // the runs cannot leave it unseen. The answer also carries the decision.
        var listedNumbers = records.Select(r => r.InvoiceNumber).ToHashSet();
        foreach (var old in invoices.Where(i => i.CreatedAt < since && InvoiceStatus.Unsettled.Contains(i.Status)
                                                && !listedNumbers.Contains(i.InvoiceNumber)))
        {
            if (RecentlyNotFound(old, now))
            {
                skipped++;
                continue;
            }

            var found = await erp.FindAsync(old.InvoiceNumber, ct);
            LogLookup(runId, old.InvoiceNumber, found);
            switch (found.Lookup)
            {
                case ErpLookup.Found when found.Records is not null:
                    records.AddRange(found.Records);
                    decisions[old.InvoiceNumber] = found.Decision ?? ErpDecision.None;
                    checks.Add(new(old.InvoiceNumber, ErpCheckResult.Found(decisions[old.InvoiceNumber].Kind)));
                    break;
                case ErpLookup.NotFound:
                    checks.Add(new(old.InvoiceNumber, ErpCheckResult.NotFound));
                    break;
                default:
                    throw new ReconciliationFailedException(
                        $"{old.InvoiceNumber} için ERP'den kayıt alınamadı: {found.Error ?? "cevaptaki kayıtlar okunamadı"}");
            }
        }

        var snapshot = new ReconciliationSnapshot(now, invoices, records, unknownEvents);

        foreach (var number in planner.InvoicesToAsk(snapshot))
        {
            if (decisions.ContainsKey(number))
                continue;

            var found = await erp.FindAsync(number, ct);
            LogLookup(runId, number, found);
            if (found.Lookup != ErpLookup.Found)
            {
                throw new ReconciliationFailedException(
                    $"{number} için ERP'den karar alınamadı: {found.Error ?? "ERP kaydı bulunamadı"}");
            }
            decisions[number] = found.Decision ?? ErpDecision.None;
            checks.Add(new(number, ErpCheckResult.Found(decisions[number].Kind)));
        }

        logger.LogInformation(
            "Reconciliation ERP lookups run={RunId} asked={Asked} notFound={NotFound} skippedRecentlyNotFound={Skipped}",
            runId, checks.Count, checks.Count(c => c.Result == ErpCheckResult.NotFound), skipped);
        return (planner.Plan(snapshot, decisions), checks);
    }

    /// <summary>
    /// A Başarısız invoice the ERP said "not there" about, recently enough and with nothing changed on it since: asking
    /// again would only get the same answer. Only Başarısız: an old Gönderildi the ERP does not have is "ERP Kaydı Yok"
    /// and must be reported by every run.
    /// </summary>
    private bool RecentlyNotFound(Invoice invoice, DateTimeOffset now) =>
        invoice.Status == InvoiceStatus.Failed
        && invoice.ErpCheckResult == ErpCheckResult.NotFound
        && invoice.ErpCheckedAt is { } checkedAt
        && checkedAt >= invoice.UpdatedAt
        && now - checkedAt < options.Value.NotFoundRecheck;

    private void LogLookup(long runId, string invoiceNumber, ErpLookupResult found) =>
        logger.LogInformation("Reconciliation asked the ERP run={RunId} invoice={InvoiceNumber} answer={Answer} decision={Decision}",
            runId, invoiceNumber, found.Lookup, found.Decision?.Kind ?? "-");

    /// <summary>
    /// Records a fix that failed as a finding that was only reported, with the reason, so the report shows it. In a scope
    /// of its own, and a failure to record it is only logged: the other fixes go on.
    /// </summary>
    private async Task<bool> ReportUnfixedAsync(long runId, PlannedFinding finding, string reason)
    {
        try
        {
            await using var scope = scopes.CreateAsyncScope();
            scope.ServiceProvider.GetRequiredService<IReconciliationStore>().AddFinding(new ReconciliationFinding
            {
                RunId = runId, InvoiceNumber = finding.InvoiceNumber, FindingType = finding.FindingType,
                Action = FindingAction.Reported, Details = $"Düzeltme uygulanamadı: {reason}", CreatedAt = time.GetUtcNow()
            });
            await scope.ServiceProvider.GetRequiredService<IUnitOfWork>().SaveChangesAsync(CancellationToken.None);
            return true;
        }
        catch (Exception ex)
        {
            logger.LogWarning("Reconciliation could not record the failed fix run={RunId} invoice={InvoiceNumber}: {Message}",
                runId, finding.InvoiceNumber, ex.GetBaseException().Message);
            return false;
        }
    }

    private ReconciliationFinding ToEntity(long runId, PlannedFinding finding) => new()
    {
        RunId = runId, InvoiceNumber = finding.InvoiceNumber, FindingType = finding.FindingType,
        Action = FindingAction.Reported, Details = finding.Details, CreatedAt = time.GetUtcNow()
    };
}
