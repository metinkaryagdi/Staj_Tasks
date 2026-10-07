using InvoiceService.Application.Reconciliation;
using InvoiceService.Application.Tests.Fakes;
using InvoiceService.Domain.Reconciliation;

namespace InvoiceService.Application.Tests;

public class ReconciliationQueriesTests
{
    private readonly Scenario _s = new();

    [Fact]
    public async Task Runs_are_listed_a_page_at_a_time_newest_first_with_the_total()
    {
        for (var id = 1; id <= 120; id++)
            _s.Reconciliation.Runs.Add(new ReconciliationRun { Id = id, Status = ReconciliationStatus.Completed });
        var queries = new ReconciliationQueries(_s.Reconciliation);

        var pages = new List<long>();
        for (var page = 1; page <= 3; page++)
        {
            var (items, total) = await queries.ListRunsAsync(page, ReconciliationQueries.MaxPageSize, CancellationToken.None);
            Assert.Equal(120, total);
            pages.AddRange(items.Select(r => r.Id));
        }

        Assert.Equal(Enumerable.Range(1, 120).Reverse().Select(i => (long)i), pages);
    }
}
