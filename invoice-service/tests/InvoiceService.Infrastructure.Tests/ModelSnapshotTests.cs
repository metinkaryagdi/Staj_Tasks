using InvoiceService.Infrastructure.Persistence;
using Microsoft.EntityFrameworkCore;

namespace InvoiceService.Infrastructure.Tests;

public class ModelSnapshotTests
{
    /// <summary>
    /// The migrations' model snapshot must describe exactly the schema the DbContext builds (tables, columns, keys,
    /// indexes, constraints), otherwise the next `dotnet ef migrations add` would generate changes nobody made and
    /// Migrate would refuse to run. Moving the entity classes into other projects must not change the schema.
    /// No database is needed.
    /// </summary>
    [Fact]
    public void Migrations_describe_the_current_model()
    {
        var options = new DbContextOptionsBuilder<InvoiceDbContext>()
            .UseNpgsql("Host=unused;Database=unused")
            .Options;
        using var db = new InvoiceDbContext(options);

        Assert.False(db.Database.HasPendingModelChanges());
    }
}
