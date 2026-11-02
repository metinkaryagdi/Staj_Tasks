using System.Text.RegularExpressions;
using ErpSimulator.Infrastructure.Persistence;
using Microsoft.EntityFrameworkCore;
using Npgsql;

namespace ErpSimulator.Api.Startup;

public static partial class DatabaseMigrator
{
    /// <summary>
    /// Run with --migrate-only, as the database's owner (docker-compose.yml, erp-migrate): applies the migrations, then
    /// gives the application's own user only what the simulator needs. The simulator itself does not migrate, so it never
    /// holds the owner's password.
    /// </summary>
    public static async Task MigrateAndGrantAsync(this WebApplication app)
    {
        await app.MigrateDatabaseAsync();
        await using var scope = app.Services.CreateAsyncScope();
        var db = scope.ServiceProvider.GetRequiredService<ErpDbContext>();
        await GrantAppUserAsync(db, app.Configuration, app.Logger);
    }

    /// <summary>Applies the migrations, waiting for the database to come up (10 attempts, 2 seconds apart).</summary>
    private static async Task MigrateDatabaseAsync(this WebApplication app)
    {
        var logger = app.Logger;
        for (var attempt = 1; ; attempt++)
        {
            try
            {
                await using var scope = app.Services.CreateAsyncScope();
                var db = scope.ServiceProvider.GetRequiredService<ErpDbContext>();
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

    // Tables whose rows the simulator changes. The others are only added to and read (invoices: a record never changes once
    // written). A new table the simulator updates goes here.
    private static readonly string[] UpdatedTables = ["webhook_deliveries"];

    /// <summary>
    /// Creates the application's user (or updates its password) and grants it rows only: SELECT and INSERT on the tables,
    /// UPDATE on <see cref="UpdatedTables"/>, the sequences for new numbers, and a connection to this database alone. It owns
    /// nothing, so it cannot drop or alter a table, and it cannot connect to the server's other databases. Run after every
    /// migration, so new tables are covered too.
    /// </summary>
    private static async Task GrantAppUserAsync(ErpDbContext db, IConfiguration configuration, ILogger logger)
    {
        var user = configuration["AppDatabaseUser:Name"] ?? "";
        var password = configuration["AppDatabaseUser:Password"] ?? "";
        if (password == "")
        {
            logger.LogWarning("AppDatabaseUser:Password is empty: the application user {User} was not created or changed", user);
            return;
        }
        // DDL takes no parameters: the name must be a plain identifier and the password goes in as a quoted literal.
        if (!IdentifierPattern().IsMatch(user))
            throw new InvalidOperationException($"AppDatabaseUser:Name '{user}' is not a plain PostgreSQL name (a-z, 0-9, _).");
        var database = new NpgsqlConnectionStringBuilder(db.Database.GetConnectionString()).Database!;
        var literal = "'" + password.Replace("'", "''") + "'";
        var updated = string.Join(", ", UpdatedTables.Select(t => $"\"{t}\""));

        await db.Database.ExecuteSqlRawAsync($"""
            DO $$ BEGIN
                IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = '{user}') THEN CREATE ROLE "{user}" LOGIN; END IF;
            END $$;
            ALTER ROLE "{user}" WITH LOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOREPLICATION NOBYPASSRLS PASSWORD {literal};
            REVOKE CONNECT ON DATABASE postgres, template1 FROM PUBLIC;
            REVOKE ALL ON DATABASE "{database}" FROM PUBLIC;
            GRANT CONNECT ON DATABASE "{database}" TO "{user}";
            GRANT USAGE ON SCHEMA public TO "{user}";
            REVOKE ALL ON ALL TABLES IN SCHEMA public FROM "{user}";
            GRANT SELECT, INSERT ON ALL TABLES IN SCHEMA public TO "{user}";
            GRANT UPDATE ON {updated} TO "{user}";
            GRANT USAGE, SELECT ON ALL SEQUENCES IN SCHEMA public TO "{user}";
            REVOKE ALL ON "__EFMigrationsHistory" FROM "{user}";
            """);
        logger.LogInformation("Application user {User} can read and write the rows of {Database}", user, database);
    }

    [GeneratedRegex("^[a-z_][a-z0-9_]*$")]
    private static partial Regex IdentifierPattern();
}
