using InvoiceService.Application.Abstractions;

namespace InvoiceService.Application.Tests;

public class ErpVersionTests
{
    private static readonly string[] Numbers = Enumerable.Range(1, 10_000).Select(i => $"FTR-{i:000000}").ToArray();

    [Fact]
    public void At_0_percent_all_use_v1_and_at_100_percent_all_use_v2()
    {
        Assert.All(Numbers, n => Assert.Equal(ErpVersion.V1, ErpVersion.For(n, 0)));
        Assert.All(Numbers, n => Assert.Equal(ErpVersion.V2, ErpVersion.For(n, 100)));
    }

    [Theory]
    [InlineData(10)]
    [InlineData(50)]
    public void The_share_is_about_what_was_asked_for_on_sequential_numbers(int percent)
    {
        var share = Numbers.Count(n => ErpVersion.For(n, percent) == ErpVersion.V2) * 100.0 / Numbers.Length;

        Assert.InRange(share, percent - 2, percent + 2);
    }

    [Fact]
    public void Raising_the_share_only_moves_invoices_to_v2()
    {
        foreach (var number in Numbers)
        {
            if (ErpVersion.For(number, 10) == ErpVersion.V2)
                Assert.Equal(ErpVersion.V2, ErpVersion.For(number, 50));
        }
    }

    [Theory]
    [InlineData(0, ErpVersion.V1)]
    [InlineData(99, ErpVersion.V1)]
    [InlineData(100, ErpVersion.V2)]
    public void The_list_leaves_v1_last(int percent, int version) => Assert.Equal(version, ErpVersion.ForList(percent));
}
