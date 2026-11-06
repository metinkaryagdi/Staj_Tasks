using InvoiceService.Application.Abstractions;
using Microsoft.EntityFrameworkCore;
using Microsoft.Extensions.DependencyInjection;

namespace InvoiceService.Infrastructure.Persistence;

/// <summary>
/// The row in erp_version_setting. Read on every ERP request, in a scope of its own: the caller's DbContext may be in the
/// middle of something else.
/// </summary>
public sealed class ErpVersionSetting(IServiceScopeFactory scopes) : IErpVersionSetting
{
    public async Task<int> GetV2PercentAsync(CancellationToken ct)
    {
        await using var scope = scopes.CreateAsyncScope();
        var db = scope.ServiceProvider.GetRequiredService<InvoiceDbContext>();
        return (await db.Database.SqlQuery<int>($"""SELECT v2_percent AS "Value" FROM erp_version_setting WHERE id = 1""").ToListAsync(ct)).Single();
    }

    public async Task SetV2PercentAsync(int percent, CancellationToken ct)
    {
        await using var scope = scopes.CreateAsyncScope();
        var db = scope.ServiceProvider.GetRequiredService<InvoiceDbContext>();
        await db.Database.ExecuteSqlInterpolatedAsync($"UPDATE erp_version_setting SET v2_percent = {percent} WHERE id = 1", ct);
    }
}
