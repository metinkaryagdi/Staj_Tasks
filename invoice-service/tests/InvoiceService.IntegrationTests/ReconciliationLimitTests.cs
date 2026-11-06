using InvoiceService.Application.Reconciliation;
using InvoiceService.Domain.Invoices;
using InvoiceService.Domain.Reconciliation;
using InvoiceService.IntegrationTests.Support;
using Microsoft.AspNetCore.Http;
using Microsoft.Extensions.DependencyInjection;
using Microsoft.Extensions.Options;

namespace InvoiceService.IntegrationTests;

/// <summary>
/// The questions a run asks about old invoices: limited, in turn, and one missing answer stops nothing. Through the real
/// store, the real ERP client and a fake ERP.
/// </summary>
public class ReconciliationLimitTests(PostgresFixture postgres) : IntegrationTest(postgres)
{
    private const int Limit = 1000; // smaller than the shipped value, so these tests stay quick

    private Task SeedOldApprovedAsync(int count) => ExecuteAsync($"""
        INSERT INTO invoices (invoice_number, customer_code, amount, currency, invoice_date, status, erp_reference, send_attempt_count, created_at, updated_at)
        SELECT 'ESKI-' || lpad(n::text, 6, '0'), 'C1', 10, 'TRY', DATE '2026-01-01', '{InvoiceStatus.Approved}', 'ERP-' || n, 1,
               now() - interval '10 days' + n * interval '1 second', now() - interval '10 days'
        FROM generate_series(1, {count}) n
        """);

    private static IResult Answer(string number, string? cancelReference = null) => Results.Ok(new
    {
        erpReference = "ERP-" + int.Parse(number["ESKI-".Length..]),
        cancelReference,
        decision = cancelReference is null ? "approved" : "cancelled",
        records = new[]
        {
            new
            {
                erpReference = "ERP-" + int.Parse(number["ESKI-".Length..]), customerCode = "C1", amount = 10m, currency = "TRY",
                invoiceDate = new DateOnly(2026, 1, 1), receivedAt = DateTimeOffset.UtcNow.AddDays(-10)
            }
        }
    });

    private async Task<ReconciliationRun> RunAsync()
    {
        await using var scope = NewScope();
        scope.ServiceProvider.GetRequiredService<IOptions<ReconciliationOptions>>().Value.MaxErpLookupsPerRun = Limit;
        var service = scope.ServiceProvider.GetRequiredService<ReconciliationService>();
        var started = await service.TryStartAsync(by: null, CancellationToken.None);
        await service.ExecuteAsync(started!, CancellationToken.None);
        var (runs, _) = await scope.ServiceProvider.GetRequiredService<Application.Abstractions.IReconciliationStore>()
            .ListRunsPageAsync(0, 1, CancellationToken.None);
        return runs[0];
    }

    private Task<string?> StatusAsync(string number) =>
        ScalarAsync<string>("SELECT status FROM invoices WHERE invoice_number = @n", ("n", number));

    [Theory]
    [InlineData(1500)]
    [InlineData(5000)]
    public async Task The_questions_of_a_run_stay_at_the_limit_however_many_old_invoices_there_are(int oldInvoices)
    {
        await SeedOldApprovedAsync(oldInvoices);
        Erp.OnGet = number => Answer(number);

        var run = await RunAsync();

        Assert.Equal(ReconciliationStatus.Completed, run.Status);
        Assert.Equal(Limit, Erp.Lookups.Count);
        Assert.Equal(Limit, Erp.Lookups.Distinct().Count());
    }

    [Fact]
    public async Task The_next_run_goes_on_with_the_ones_not_asked_yet_and_finds_a_lost_cancellation()
    {
        await SeedOldApprovedAsync(1500);
        var lost = "ESKI-001200"; // beyond the first run's limit
        Erp.OnGet = number => number == lost ? Answer(number, "IPT-1") : Answer(number);

        await RunAsync();
        Assert.DoesNotContain(lost, Erp.Lookups);
        Assert.Equal(InvoiceStatus.Approved, await StatusAsync(lost));

        Erp.Lookups.Clear();
        await RunAsync();

        Assert.Equal(1000, Erp.Lookups.Count);
        Assert.Equal(1000 - 500, Erp.Lookups.Count(n => string.CompareOrdinal(n, "ESKI-001000") <= 0));
        Assert.Contains(lost, Erp.Lookups);
        Assert.Equal(InvoiceStatus.Cancelled, await StatusAsync(lost));
    }

    [Fact]
    public async Task One_invoice_without_an_answer_does_not_stop_the_others_and_is_asked_first_in_the_next_run()
    {
        await SeedOldApprovedAsync(10);
        const string failing = "ESKI-000003", cancelled = "ESKI-000007";
        Erp.OnGet = number => number == failing
            ? Results.Problem(statusCode: 500, title: "ERP hatası")
            : number == cancelled ? Answer(number, "IPT-1") : Answer(number);

        var run = await RunAsync();

        Assert.Equal(ReconciliationStatus.Completed, run.Status);
        Assert.Null(run.Error);
        Assert.Equal(10, Erp.Lookups.Count);
        Assert.Equal(InvoiceStatus.Cancelled, await StatusAsync(cancelled));
        // Left out and unchanged; the only finding about it says that it was skipped.
        Assert.Equal(InvoiceStatus.Approved, await StatusAsync(failing));
        Assert.Equal("Cevap Alınamadı", await ScalarAsync<string>("SELECT finding_type FROM reconciliation_findings WHERE invoice_number = @n", ("n", failing)));
        Assert.Equal(1L, await ScalarAsync<long>("SELECT count(*) FROM reconciliation_findings WHERE invoice_number = @n", ("n", failing)));

        // Still no answer: it shows again in the next run.
        Erp.Lookups.Clear();
        await RunAsync();
        Assert.Equal(failing, Erp.Lookups[0]);
        Assert.Equal(2L, await ScalarAsync<long>("SELECT count(*) FROM reconciliation_findings WHERE invoice_number = @n", ("n", failing)));

        Erp.Lookups.Clear();
        Erp.OnGet = number => Answer(number);
        await RunAsync();

        Assert.Equal(failing, Erp.Lookups[0]);
        Assert.Equal(2L, await ScalarAsync<long>("SELECT count(*) FROM reconciliation_findings WHERE invoice_number = @n", ("n", failing)));
    }
}
