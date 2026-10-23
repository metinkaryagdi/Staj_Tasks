using InvoiceService.Application.Invoices;
using InvoiceService.Application.Reconciliation;
using InvoiceService.Domain.Operators;
using InvoiceService.IntegrationTests.Support;
using Microsoft.Extensions.DependencyInjection;

namespace InvoiceService.IntegrationTests;

/// <summary>That the token's sub reaches the database next to the user name; the in-memory stores cannot show it.</summary>
public class OperatorSubTests(PostgresFixture postgres) : IntegrationTest(postgres)
{
    private static readonly OperatorIdentity Operator = new("operator", "61c2c0de-8ead-48a6-a042-c0fbfabc9a68");

    [Fact]
    public async Task An_intervention_is_recorded_with_the_sub()
    {
        await using (var scope = NewScope())
            await scope.ServiceProvider.GetRequiredService<ResendInvoiceHandler>().HandleAsync("FTR-999999", Operator);

        Assert.Equal(Operator.Sub, await ScalarAsync<string>(
            "SELECT operator_sub FROM operator_actions WHERE invoice_number = 'FTR-999999' AND operator_name = 'operator'"));
    }

    [Fact]
    public async Task A_run_started_by_an_operator_keeps_the_sub()
    {
        await using var scope = NewScope();
        var started = await scope.ServiceProvider.GetRequiredService<ReconciliationService>()
            .TryStartAsync(Operator, CancellationToken.None);
        await started!.Lease.DisposeAsync();

        Assert.Equal(Operator.Sub, await ScalarAsync<string>(
            "SELECT started_by_sub FROM reconciliation_runs WHERE id = @id", ("id", started.Run.Id)));
        Assert.Equal(Operator.Sub, await ScalarAsync<string>(
            "SELECT operator_sub FROM operator_actions WHERE action = 'Mutabakat Başlatma'"));
    }
}
