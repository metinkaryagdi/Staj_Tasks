namespace InvoiceService.Api;

/// <summary>The page and pageSize query values of a paged list: checked, with their defaults filled in.</summary>
public static class Paging
{
    /// <summary>Adds to <paramref name="errors"/> what is wrong; the returned values are only meant to be used when
    /// nothing was added.</summary>
    public static (int Page, int Size) Read(
        int? page, int? pageSize, int defaultSize, int maxSize, Dictionary<string, string[]> errors)
    {
        if (page is < 1)
            errors["page"] = ["Must be 1 or greater."];
        if (pageSize is < 1 || pageSize > maxSize)
            errors["pageSize"] = [$"Must be between 1 and {maxSize}."];

        var currentPage = page ?? 1;
        var size = pageSize ?? defaultSize;
        // The rows to skip must fit an int; a page that far is empty anyway.
        if (currentPage > 1 && (long)(currentPage - 1) * size > int.MaxValue)
            errors["page"] = ["Too large for this page size."];
        return (currentPage, size);
    }

    public static int TotalPages(int totalCount, int size) => (totalCount + size - 1) / size;
}
