using Microsoft.EntityFrameworkCore;

namespace InvoiceService.Data;

public sealed class InvoiceDbContext(DbContextOptions<InvoiceDbContext> options) : DbContext(options)
{
    private const string InvoiceNumberSequence = "invoice_number_seq";

    public DbSet<Invoice> Invoices => Set<Invoice>();

    public DbSet<ErpOutboxEntry> ErpOutbox => Set<ErpOutboxEntry>();

    public DbSet<ErpWebhookEvent> ErpWebhookEvents => Set<ErpWebhookEvent>();

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
                t.HasCheckConstraint("ck_invoices_status", InList("status", InvoiceStatus.All));
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
            entity.Property(e => e.RejectReason).HasColumnName("reject_reason");
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
            entity.Property(e => e.ClaimToken).HasColumnName("claim_token");

            // The worker's query: pending entries whose time has come, oldest first.
            entity.HasIndex(e => new { e.Status, e.NextAttemptAt });
        });

        modelBuilder.Entity<ErpWebhookEvent>(entity =>
        {
            entity.ToTable("erp_webhook_events", t =>
            {
                t.HasCheckConstraint("ck_erp_webhook_events_status", InList("status", WebhookEventStatus.All));
                t.HasCheckConstraint("ck_erp_webhook_events_event_type", InList("event_type", WebhookEventType.All));
                t.HasCheckConstraint("ck_erp_webhook_events_delivery_count", "delivery_count >= 1");
            });

            // The primary key is what makes a repeated event_id impossible to store twice.
            entity.HasKey(e => e.EventId);
            entity.Property(e => e.EventId).HasColumnName("event_id").HasMaxLength(64);

            entity.Property(e => e.EventType).HasColumnName("event_type").HasMaxLength(32);
            // No foreign key to invoices: an event may arrive before the invoice is known here and must still be kept.
            entity.Property(e => e.InvoiceNumber).HasColumnName("invoice_number").HasMaxLength(32);
            entity.Property(e => e.ErpReference).HasColumnName("erp_reference").HasMaxLength(32);
            entity.Property(e => e.OccurredAt).HasColumnName("occurred_at");
            entity.Property(e => e.ReceivedAt).HasColumnName("received_at");
            entity.Property(e => e.ProcessedAt).HasColumnName("processed_at");
            entity.Property(e => e.Status).HasColumnName("status").HasMaxLength(16);
            entity.Property(e => e.Payload).HasColumnName("payload");
            entity.Property(e => e.DeliveryCount).HasColumnName("delivery_count").HasDefaultValue(1);

            // Finding an invoice's events still waiting for it (Bekliyor) when it becomes Gönderildi.
            entity.HasIndex(e => new { e.InvoiceNumber, e.Status });
        });
    }

    private static string InList(string column, IEnumerable<string> values) =>
        $"{column} IN ({string.Join(", ", values.Select(v => $"'{v}'"))})";
}
