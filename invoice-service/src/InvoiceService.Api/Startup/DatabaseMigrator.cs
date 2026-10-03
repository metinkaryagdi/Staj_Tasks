using InvoiceService.Infrastructure.Persistence;
using Microsoft.EntityFrameworkCore;

namespace InvoiceService.Api.Startup;

public static class DatabaseMigrator
{
    /// <summary>Applies the migrations, waiting for the database to come up (10 attempts, 2 seconds apart).</summary>
    public static async Task MigrateDatabaseAsync(this WebApplication app)
    {
        var logger = app.Logger;
        for (var attempt = 1; ; attempt++)
        {
            try
            {
                await using var scope = app.Services.CreateAsyncScope();
                var db = scope.ServiceProvider.GetRequiredService<InvoiceDbContext>();
                await db.Database.MigrateAsync();
                return;
            }
            catch (Exception ex) when (attempt < 10)
            {
                logger.LogWarning("Database not ready (attempt {Attempt}/10): {Message}", attempt, ex.Message);
                await Task.Delay(TimeSpan.FromSeconds(2));
            }
        }
    }
}
