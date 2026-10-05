using InvoiceService.Domain.Reconciliation;

namespace InvoiceService.Domain.Tests;

public class FindingTypeTests
{
    [Fact]
    public void The_types_a_run_fixes_are_among_all_the_types_and_are_not_the_only_ones()
    {
        Assert.All(FindingType.Fixable, type => Assert.Contains(type, FindingType.All));
        Assert.True(FindingType.Fixable.Length < FindingType.All.Length);
    }

    [Fact]
    public void Type_names_are_unique_and_fit_their_column()
    {
        Assert.Equal(FindingType.All.Length, FindingType.All.Distinct().Count());
        Assert.All(FindingType.All, type => Assert.InRange(type.Length, 1, 32));
    }

    [Fact]
    public void Constants_that_go_into_check_constraints_have_no_apostrophe()
    {
        // The constraints are built by wrapping each value in single quotes; an apostrophe would end the string early.
        Assert.All(FindingType.All.Concat(FindingAction.All).Concat(ReconciliationStatus.All),
            value => Assert.DoesNotContain('\'', value));
    }
}
