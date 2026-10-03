using ErpSimulator.Domain.Invoices;
using ErpSimulator.Domain.Webhooks;
using Microsoft.EntityFrameworkCore;

namespace ErpSimulator.Infrastructure.Persistence;

public sealed class ErpDbContext(DbContextOptions<ErpDbContext> options) : DbContext(options)
{
    public DbSet<ErpInvoice> Invoices => Set<ErpInvoice>();

    public DbSet<WebhookDelivery> WebhookDeliveries => Set<WebhookDelivery>();

    protected override void OnModelCreating(ModelBuilder modelBuilder)
    {
        modelBuilder.HasSequence<long>("erp_reference_seq");

        modelBuilder.Entity<ErpInvoice>(entity =>
        {
            entity.ToTable("invoices");

            entity.HasKey(e => e.Id);
            entity.Property(e => e.Id).HasColumnName("id");

            entity.Property(e => e.ErpReference)
                .HasColumnName("erp_reference")
                .HasMaxLength(32)
                .HasDefaultValueSql("'ERP-' || lpad(nextval('erp_reference_seq')::text, 8, '0')");
            entity.HasIndex(e => e.ErpReference).IsUnique();

            entity.Property(e => e.InvoiceNumber).HasColumnName("invoice_number").HasMaxLength(64);
            entity.HasIndex(e => e.InvoiceNumber);

            entity.Property(e => e.CustomerCode).HasColumnName("customer_code").HasMaxLength(64);
            entity.Property(e => e.Amount).HasColumnName("amount").HasPrecision(18, 2);
            entity.Property(e => e.Currency).HasColumnName("currency").HasMaxLength(3).IsFixedLength();
            entity.Property(e => e.InvoiceDate).HasColumnName("invoice_date");
            entity.Property(e => e.ReceivedAt).HasColumnName("received_at");
            entity.Property(e => e.Behavior).HasColumnName("behavior").HasMaxLength(32);
            entity.Property(e => e.RequestSequence).HasColumnName("request_sequence");
        });

        modelBuilder.Entity<WebhookDelivery>(entity =>
        {
            entity.ToTable("webhook_deliveries", t =>
            {
                t.HasCheckConstraint("ck_webhook_deliveries_status", InList("status", DeliveryStatus.All));
                t.HasCheckConstraint("ck_webhook_deliveries_kind", InList("kind", DeliveryKind.All));
            });

            entity.HasKey(e => e.Id);
            entity.Property(e => e.Id).HasColumnName("id").UseIdentityAlwaysColumn();

            // Not unique: a duplicate delivery repeats the event_id on purpose.
            entity.Property(e => e.EventId).HasColumnName("event_id").HasMaxLength(64);
            entity.HasIndex(e => e.EventId);
            entity.Property(e => e.EventType).HasColumnName("event_type").HasMaxLength(32);
            entity.Property(e => e.InvoiceId).HasColumnName("invoice_id");
            entity.HasOne<ErpInvoice>().WithMany().HasForeignKey(e => e.InvoiceId).OnDelete(DeleteBehavior.Restrict);
            entity.Property(e => e.InvoiceNumber).HasColumnName("invoice_number").HasMaxLength(64);
            entity.HasIndex(e => e.InvoiceNumber);
            entity.Property(e => e.Kind).HasColumnName("kind").HasMaxLength(16);
            entity.Property(e => e.Payload).HasColumnName("payload");
            entity.Property(e => e.OccurredAt).HasColumnName("occurred_at");
            entity.Property(e => e.DueAt).HasColumnName("due_at");
            entity.Property(e => e.Status).HasColumnName("status").HasMaxLength(16);
            entity.Property(e => e.FirstSentAt).HasColumnName("first_sent_at");
            entity.Property(e => e.AttemptCount).HasColumnName("attempt_count");
            entity.Property(e => e.LastHttpStatus).HasColumnName("last_http_status");
            entity.Property(e => e.LastError).HasColumnName("last_error");
            entity.Property(e => e.CreatedAt).HasColumnName("created_at");
            entity.Property(e => e.CompletedAt).HasColumnName("completed_at");

            // The dispatcher's query: pending rows whose time has come.
            entity.HasIndex(e => new { e.Status, e.DueAt });
        });
    }

    private static string InList(string column, IEnumerable<string> values) =>
        $"{column} IN ({string.Join(", ", values.Select(v => $"'{v}'"))})";
}
