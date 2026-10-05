using ErpSimulator.Application.Invoices;
using ErpSimulator.Application.Tests.Fakes;
using ErpSimulator.Domain.Invoices;

namespace ErpSimulator.Application.Tests;

/// <summary>Listing the ERP's records received in a time range.</summary>
public class InvoiceListingTests
{
    private static readonly DateTimeOffset Start = new(2026, 10, 5, 9, 0, 0, TimeSpan.Zero);

    private readonly FakeErpInvoiceStore _store = new();

    private InvoiceListing Listing => new(_store);

    private async Task AddAsync(string number, int minutesAfterStart)
    {
        await _store.SaveAsync(new ErpInvoice
        {
            InvoiceNumber = number, CustomerCode = "C-001", Currency = "TRY", Behavior = "Success",
            ReceivedAt = Start.AddMinutes(minutesAfterStart)
        }, _ => []);
    }

    private static InvoiceListRequest Range(int fromMinutes, int toMinutes, int page = 1, int pageSize = 100) =>
        new(Start.AddMinutes(fromMinutes), Start.AddMinutes(toMinutes), page, pageSize);

    [Fact]
    public async Task The_range_includes_from_and_excludes_to()
    {
        await AddAsync("INV-0", -1);
        await AddAsync("INV-1", 0);
        await AddAsync("INV-2", 5);
        await AddAsync("INV-3", 10);

        var result = await Listing.ListAsync(Range(0, 10), CancellationToken.None);

        Assert.Equal(["INV-1", "INV-2"], result.Page!.Items.Select(i => i.InvoiceNumber));
        Assert.Equal(2, result.Page.TotalCount);
    }

    [Fact]
    public async Task Records_come_in_received_order_and_a_duplicated_number_is_listed_per_record()
    {
        await AddAsync("INV-B", 2);
        await AddAsync("INV-A", 1);
        await AddAsync("INV-A", 3);

        var result = await Listing.ListAsync(Range(0, 10), CancellationToken.None);

        Assert.Equal(["INV-A", "INV-B", "INV-A"], result.Page!.Items.Select(i => i.InvoiceNumber));
    }

    [Fact]
    public async Task A_page_is_cut_from_the_ordered_range_and_the_total_counts_all_of_it()
    {
        for (var i = 0; i < 5; i++)
            await AddAsync($"INV-{i}", i);

        var second = await Listing.ListAsync(Range(0, 10, page: 2, pageSize: 2), CancellationToken.None);
        var last = await Listing.ListAsync(Range(0, 10, page: 3, pageSize: 2), CancellationToken.None);
        var beyond = await Listing.ListAsync(Range(0, 10, page: 4, pageSize: 2), CancellationToken.None);

        Assert.Equal(["INV-2", "INV-3"], second.Page!.Items.Select(i => i.InvoiceNumber));
        Assert.Equal(["INV-4"], last.Page!.Items.Select(i => i.InvoiceNumber));
        Assert.Empty(beyond.Page!.Items);
        Assert.Equal(5, beyond.Page.TotalCount);
    }

    [Fact]
    public async Task A_page_number_so_large_that_the_offset_would_overflow_is_an_empty_page()
    {
        await AddAsync("INV-0", 0);
        await AddAsync("INV-1", 1);

        var result = await Listing.ListAsync(Range(0, 10, page: int.MaxValue, pageSize: 500), CancellationToken.None);

        Assert.Null(result.Errors);
        Assert.Empty(result.Page!.Items);
        Assert.Equal(2, result.Page.TotalCount);
    }

    [Theory]
    [InlineData(0, nameof(InvoiceListRequest.PageSize))]
    [InlineData(501, nameof(InvoiceListRequest.PageSize))]
    public async Task A_page_size_outside_1_to_500_is_refused(int pageSize, string field)
    {
        var result = await Listing.ListAsync(Range(0, 10, pageSize: pageSize), CancellationToken.None);

        Assert.Null(result.Page);
        Assert.Contains(field, result.Errors!.Keys);
    }

    [Fact]
    public async Task The_largest_page_size_is_accepted()
    {
        var result = await Listing.ListAsync(Range(0, 10, pageSize: 500), CancellationToken.None);

        Assert.Null(result.Errors);
    }

    [Fact]
    public async Task Page_below_1_and_a_missing_or_reversed_range_are_refused()
    {
        var page = await Listing.ListAsync(Range(0, 10, page: 0), CancellationToken.None);
        var missing = await Listing.ListAsync(new InvoiceListRequest(null, Start, 1, 100), CancellationToken.None);
        var reversed = await Listing.ListAsync(Range(10, 0), CancellationToken.None);
        var empty = await Listing.ListAsync(Range(5, 5), CancellationToken.None);

        Assert.Contains(nameof(InvoiceListRequest.Page), page.Errors!.Keys);
        Assert.Contains(nameof(InvoiceListRequest.From), missing.Errors!.Keys);
        Assert.Contains(nameof(InvoiceListRequest.To), reversed.Errors!.Keys);
        Assert.Contains(nameof(InvoiceListRequest.To), empty.Errors!.Keys);
    }
}
