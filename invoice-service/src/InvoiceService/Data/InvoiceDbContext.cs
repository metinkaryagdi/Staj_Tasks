using Microsoft.EntityFrameworkCore;

namespace InvoiceService.Data;

public sealed class InvoiceDbContext(DbContextOptions<InvoiceDbContext> options) : DbContext(options)
{
    private const string InvoiceNumberSequence = "invoice_number_seq";

    public DbSet<Invoice> Invoices => Set<Invoice>();

    public DbSet<ErpOutboxEntry> ErpOutbox => Set<ErpOutboxEntry>();

    /// <summary>Takes the next value from the sequence; numbers are never reused, even if the insert later fails.</summary>
    public async Task<string> NextInvoiceNumberAsync(CancellationToken ct)
    {
        var value = await Database
            .SqlQueryRaw<long>($"SELECT nextval('{InvoiceNumberSequence}') AS \"Value\"")
            .SingleAsync(ct);
        return InvoiceNumber.Format(value);
    }

    protected override void OnModelCreating(ModelBuilder modelBuilder)
    {
        modelBuilder.HasSequence<long>(InvoiceNumberSequence);

        modelBuilder.Entity<Invoice>(entity =>
        {
            entity.ToTable("invoices", t =>
            {
                t.HasCheckConstraint("ck_invoices_status",
                    $"status IN ('{InvoiceStatus.Pending}', '{InvoiceStatus.Sent}', '{InvoiceStatus.Failed}')");
                t.HasCheckConstraint("ck_invoices_currency", "currency ~ '^[A-Z]{3}$'");
            });

            entity.HasKey(e => e.InvoiceNumber);
            entity.Property(e => e.InvoiceNumber).HasColumnName("invoice_number").HasMaxLength(32);

            entity.Property(e => e.CustomerCode).HasColumnName("customer_code").HasMaxLength(64);
            entity.Property(e => e.Amount).HasColumnName("amount").HasPrecision(18, 2);
            entity.Property(e => e.Currency).HasColumnName("currency").HasMaxLength(3).IsFixedLength();
            entity.Property(e => e.InvoiceDate).HasColumnName("invoice_date");
            entity.Property(e => e.Status).HasColumnName("status").HasMaxLength(16);
            entity.Property(e => e.ErpReference).HasColumnName("erp_reference").HasMaxLength(32);
            entity.Property(e => e.LastError).HasColumnName("last_error");
            entity.Property(e => e.SendAttemptCount).HasColumnName("send_attempt_count");
            entity.Property(e => e.CreatedAt).HasColumnName("created_at");
            entity.Property(e => e.UpdatedAt).HasColumnName("updated_at");
        });

        modelBuilder.Entity<ErpOutboxEntry>(entity =>
        {
            entity.ToTable("erp_outbox", t => t.HasCheckConstraint("ck_erp_outbox_status",
                $"status IN ('{OutboxStatus.Pending}', '{OutboxStatus.Completed}', '{OutboxStatus.Failed}')"));

            entity.HasKey(e => e.Id);
            entity.Property(e => e.Id).HasColumnName("id").UseIdentityAlwaysColumn();

            entity.Property(e => e.InvoiceNumber).HasColumnName("invoice_number").HasMaxLength(32);
            entity.HasIndex(e => e.InvoiceNumber).IsUnique();
            entity.HasOne<Invoice>().WithMany().HasForeignKey(e => e.InvoiceNumber).OnDelete(DeleteBehavior.Restrict);

            entity.Property(e => e.Status).HasColumnName("status").HasMaxLength(16);
            entity.Property(e => e.AttemptCount).HasColumnName("attempt_count");
            entity.Property(e => e.NextAttemptAt).HasColumnName("next_attempt_at");
            entity.Property(e => e.LastError).HasColumnName("last_error");
            entity.Property(e => e.CreatedAt).HasColumnName("created_at");
            entity.Property(e => e.ProcessedAt).HasColumnName("processed_at");
            entity.Property(e => e.LockedUntil).HasColumnName("locked_until");
            entity.Property(e => e.LockedBy).HasColumnName("locked_by").HasMaxLength(64);

            // The worker's query: pending entries whose time has come, oldest first.
            entity.HasIndex(e => new { e.Status, e.NextAttemptAt });
        });
    }
}
