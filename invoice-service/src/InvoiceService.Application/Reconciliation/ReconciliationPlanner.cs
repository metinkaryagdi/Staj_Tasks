using System.Globalization;
using InvoiceService.Application.Abstractions;
using InvoiceService.Domain.Invoices;
using InvoiceService.Domain.Reconciliation;
using InvoiceService.Domain.Webhooks;
using Microsoft.Extensions.Options;

namespace InvoiceService.Application.Reconciliation;

/// <summary>
/// Compares the service's invoices with the ERP's records and says what differs and what can be fixed. Pure: it reads
/// nothing and writes nothing, so every rule can be tested without a database or the ERP.
/// </summary>
public sealed class ReconciliationPlanner(IOptions<ReconciliationOptions> options)
{
    private TimeSpan StuckAfter => TimeSpan.FromMinutes(options.Value.StuckAfterMinutes);

    private TimeSpan UnknownEventAfter => TimeSpan.FromMinutes(options.Value.UnknownEventAfterMinutes);

    /// <summary>The invoices whose decision the ERP must be asked for before <see cref="Plan"/>.</summary>
    public IReadOnlyList<string> InvoicesToAsk(ReconciliationSnapshot snapshot) =>
        Pair(snapshot).Where(p => p.Invoice is not null && WantsDecision(p.Invoice, p.Records, snapshot.Now))
            .Select(p => p.Number).ToList();

    /// <param name="decisions">By invoice number, for the invoices <see cref="InvoicesToAsk"/> returned.</param>
    public ReconciliationPlan Plan(ReconciliationSnapshot snapshot, IReadOnlyDictionary<string, ErpDecision> decisions)
    {
        var findings = new List<PlannedFinding>();
        var pairs = Pair(snapshot);

        foreach (var (number, invoice, records) in pairs)
        {
            if (invoice is null)
            {
                findings.Add(new(number, FindingType.MissingInService,
                    $"ERP'de var ({records[0].ErpReference}, {Money(records[0].Amount)} {records[0].Currency}), serviste yok."));
                if (records.Count > 1)
                    findings.Add(DuplicateInErp(number, records));
                continue;
            }

            // Not sent yet (or being sent again): nothing to compare.
            if (invoice.Status == InvoiceStatus.Pending)
                continue;

            if (records.Count == 0)
            {
                if (InvoiceStatus.ErpHasIt.Contains(invoice.Status))
                    findings.Add(new(number, FindingType.MissingInErp, $"Serviste {invoice.Status}, ERP'de kaydı yok."));
                continue;
            }

            if (records.Count > 1)
                findings.Add(DuplicateInErp(number, records));

            var differences = Differences(invoice, records[0]);
            if (differences.Count > 0)
            {
                findings.Add(new(number, FindingType.FieldMismatch, string.Join("; ", differences) + "."));
                continue;
            }

            if (WantsDecision(invoice, records, snapshot.Now))
            {
                var decision = decisions.GetValueOrDefault(number, ErpDecision.None);
                if (FixFor(invoice, records[0], decision, snapshot.Now) is { } finding)
                    findings.Add(finding);
            }
        }

        foreach (var erpEvent in snapshot.UnknownInvoiceEvents.Where(e => snapshot.Now - e.ReceivedAt > UnknownEventAfter))
        {
            var minutes = (int)(snapshot.Now - erpEvent.ReceivedAt).TotalMinutes;
            findings.Add(new(erpEvent.InvoiceNumber, FindingType.UnknownEvent,
                $"{erpEvent.EventType} haberi ({erpEvent.EventId}) {minutes} dk önce geldi, fatura serviste yok; Yok Sayıldı yapıldı.",
                new Fix(FixKind.IgnoreEvent, erpEvent.InvoiceNumber, EventId: erpEvent.EventId)));
        }

        return new ReconciliationPlan(pairs.Count, findings);
    }

    /// <summary>
    /// Başarısız and in the ERP, or Gönderildi / İşleme Alındı for too long: the ERP's decision may move it. Not when
    /// the ERP has several records of it: which one is the right one is not known, so that invoice is only reported.
    /// </summary>
    private bool WantsDecision(Invoice invoice, IReadOnlyList<ErpRecord> records, DateTimeOffset now) =>
        records.Count == 1 && Differences(invoice, records[0]).Count == 0 &&
        (invoice.Status == InvoiceStatus.Failed
         || (invoice.Status is InvoiceStatus.Sent or InvoiceStatus.Processing && now - invoice.UpdatedAt > StuckAfter));

    private static PlannedFinding? FixFor(Invoice invoice, ErpRecord erp, ErpDecision decision, DateTimeOffset now)
    {
        var number = invoice.InvoiceNumber;

        if (invoice.Status == InvoiceStatus.Failed)
        {
            var details = $"Serviste Başarısız, ERP'de kayıtlı ({erp.ErpReference}); Gönderildi yapıldı";
            var target = DecisionTarget(InvoiceStatus.Sent, decision);
            if (target is not null)
                details += $", ERP kararı {decision.Kind}: {target} yapıldı";
            return new(number, FindingType.FailedButInErp, details + ".",
                new Fix(FixKind.RecoverFailed, number, InvoiceStatus.Failed, erp.ErpReference, decision));
        }

        var result = DecisionTarget(invoice.Status, decision);
        if (result is null)
            return null;

        var minutes = (int)(now - invoice.UpdatedAt).TotalMinutes;
        return new(number, FindingType.StuckInvoice,
            $"{invoice.Status} durumunda {minutes} dk kaldı; ERP kararı {decision.Kind}: {result} yapıldı.",
            new Fix(FixKind.ApplyDecision, number, invoice.Status, erp.ErpReference, decision));
    }

    /// <summary>
    /// The status the ERP's decision gives the invoice by the same rules as an event; null if it changes nothing.
    /// </summary>
    public static string? DecisionTarget(string status, ErpDecision decision)
    {
        var eventType = decision.Kind switch
        {
            ErpDecisionKind.Received => WebhookEventType.Received,
            ErpDecisionKind.Approved => WebhookEventType.Approved,
            ErpDecisionKind.Rejected => WebhookEventType.Rejected,
            _ => null
        };
        if (eventType is null)
            return null;

        var transition = InvoiceTransitions.For(status, eventType);
        return transition.Outcome == TransitionOutcome.Apply ? transition.NewStatus : null;
    }

    /// <summary>Amount, currency, customer code, and erp_reference when the service has one.</summary>
    private static List<string> Differences(Invoice invoice, ErpRecord erp)
    {
        var differences = new List<string>();
        if (invoice.Amount != erp.Amount)
            differences.Add($"tutar: serviste {Money(invoice.Amount)}, ERP'de {Money(erp.Amount)}");
        if (invoice.Currency != erp.Currency)
            differences.Add($"para birimi: serviste {invoice.Currency}, ERP'de {erp.Currency}");
        if (invoice.CustomerCode != erp.CustomerCode)
            differences.Add($"müşteri kodu: serviste {invoice.CustomerCode}, ERP'de {erp.CustomerCode}");
        if (invoice.ErpReference is not null && invoice.ErpReference != erp.ErpReference)
            differences.Add($"erp_reference: serviste {invoice.ErpReference}, ERP'de {erp.ErpReference}");
        return differences;
    }

    private static PlannedFinding DuplicateInErp(string number, IReadOnlyList<ErpRecord> records) =>
        new(number, FindingType.DuplicateInErp, $"ERP'de {records.Count} kayıt var: {string.Join(", ", records.Select(r => r.ErpReference))}.");

    private static string Money(decimal amount) => amount.ToString("0.00", CultureInfo.InvariantCulture);

    /// <summary>Each invoice number of either side once, in order, with its invoice and its ERP records.</summary>
    private static List<(string Number, Invoice? Invoice, IReadOnlyList<ErpRecord> Records)> Pair(ReconciliationSnapshot snapshot)
    {
        var invoices = snapshot.Invoices.ToDictionary(i => i.InvoiceNumber);
        var records = snapshot.ErpRecords.GroupBy(r => r.InvoiceNumber).ToDictionary(g => g.Key, g => (IReadOnlyList<ErpRecord>)g.ToList());
        return invoices.Keys.Union(records.Keys).Order(StringComparer.Ordinal)
            .Select(n => (n, invoices.GetValueOrDefault(n), records.GetValueOrDefault(n) ?? []))
            .ToList();
    }
}
