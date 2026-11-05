using InvoiceService.IntegrationTests.Support;

namespace InvoiceService.IntegrationTests;

/// <summary>
/// scripts/after-restore.sql against the database, with the sending code: after a backup is restored, the ERP may already
/// have what the backup still shows as waiting.
/// </summary>
public class AfterRestoreTests(PostgresFixture postgres) : IntegrationTest(postgres)
{
    /// <summary>The file the restore script runs, found from the test's folder up to the repository.</summary>
    private static string ScriptText()
    {
        for (var folder = new DirectoryInfo(AppContext.BaseDirectory); folder is not null; folder = folder.Parent)
        {
            var path = Path.Combine(folder.FullName, "scripts", "after-restore.sql");
            if (File.Exists(path))
                return File.ReadAllText(path);
        }
        throw new FileNotFoundException("scripts/after-restore.sql");
    }

    [Fact]
    public async Task An_invoice_the_backup_shows_as_waiting_that_the_erp_already_has_is_not_posted_again()
    {
        Erp.KeepRecords = true;
        var number = await CreateInvoiceAsync();
        Erp.RecordInvoice(number);

        await ExecuteAsync(ScriptText());
        await SendAllAsync();

        Assert.DoesNotContain("POST " + number, Erp.Requests);
        Assert.Equal("Gönderildi", await ScalarAsync<string>("SELECT status FROM invoices WHERE invoice_number = @n", ("n", number)));
    }

    [Fact]
    public async Task An_invoice_the_backup_shows_as_waiting_that_the_erp_does_not_have_is_posted_once()
    {
        Erp.KeepRecords = true;
        var number = await CreateInvoiceAsync();

        await ExecuteAsync(ScriptText());
        await SendAllAsync();

        Assert.Equal(["POST " + number], Erp.Requests);
    }

    [Fact]
    public async Task A_new_invoice_does_not_get_a_number_given_since_the_backup()
    {
        var before = await CreateInvoiceAsync();

        await ExecuteAsync(ScriptText());
        var after = await CreateInvoiceAsync();

        Assert.True(long.Parse(after["FTR-".Length..]) > long.Parse(before["FTR-".Length..]) + 1_000_000);
    }

    [Fact]
    public async Task An_invoice_created_after_the_restore_is_posted_without_asking()
    {
        await ExecuteAsync(ScriptText());
        var number = await CreateInvoiceAsync();

        await SendAllAsync();

        Assert.Equal(["POST " + number], Erp.Requests);
    }
}
