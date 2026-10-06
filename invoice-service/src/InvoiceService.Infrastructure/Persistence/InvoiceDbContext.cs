using InvoiceService.Domain.Invoices;
using InvoiceService.Domain.Outbox;
using InvoiceService.Domain.Reconciliation;
using InvoiceService.Domain.Webhooks;
using Microsoft.EntityFrameworkCore;

namespace InvoiceService.Infrastructure.Persistence;

public sealed class InvoiceDbContext(DbContextOptions<InvoiceDbContext> options) : DbContext(options)
{
    public const string InvoiceNumberSequence = "invoice_number_seq";

    public DbSet<Invoice> Invoices => Set<Invoice>();

    public DbSet<ErpOutboxEntry> ErpOutbox => Set<ErpOutboxEntry>();

    public DbSet<ErpWebhookEvent> ErpWebhookEvents => Set<ErpWebhookEvent>();

    public DbSet<ReconciliationRun> ReconciliationRuns => Set<ReconciliationRun>();

    public DbSet<ReconciliationFinding> ReconciliationFindings => Set<ReconciliationFinding>();

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
                t.HasCheckConstraint("ck_erp_webhook_events_ignore_reason",
                    $"(status = '{WebhookEventStatus.Ignored}') = (ignore_reason IS NOT NULL) " +
                    $"AND (ignore_reason IS NULL OR {InList("ignore_reason", IgnoreReason.All)})");
                // processed_at is "when the event was applied to the invoice": set only on İşlendi.
                t.HasCheckConstraint("ck_erp_webhook_events_processed_at",
                    $"(status = '{WebhookEventStatus.Processed}') = (processed_at IS NOT NULL)");
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
            entity.Property(e => e.IgnoreReason).HasColumnName("ignore_reason").HasMaxLength(16);
            entity.Property(e => e.Payload).HasColumnName("payload");
            entity.Property(e => e.DeliveryCount).HasColumnName("delivery_count").HasDefaultValue(1);

            // Finding an invoice's events still waiting for it (Bekliyor) when it becomes Gönderildi.
            entity.HasIndex(e => new { e.InvoiceNumber, e.Status });
        });

        modelBuilder.Entity<ReconciliationRun>(entity =>
        {
            entity.ToTable("reconciliation_runs", t =>
            {
                t.HasCheckConstraint("ck_reconciliation_runs_status", InList("status", ReconciliationStatus.All));
                t.HasCheckConstraint("ck_reconciliation_runs_finished_at",
                    $"(status = '{ReconciliationStatus.Running}') = (finished_at IS NULL)");
                t.HasCheckConstraint("ck_reconciliation_runs_error",
                    $"(status = '{ReconciliationStatus.Failed}') = (error IS NOT NULL)");
                t.HasCheckConstraint("ck_reconciliation_runs_counts",
                    "checked_count >= 0 AND fixed_count >= 0 AND reported_count >= 0");
            });

            entity.HasKey(e => e.Id);
            entity.Property(e => e.Id).HasColumnName("id").UseIdentityAlwaysColumn();
            entity.Property(e => e.StartedAt).HasColumnName("started_at");
            entity.Property(e => e.FinishedAt).HasColumnName("finished_at");
            entity.Property(e => e.Status).HasColumnName("status").HasMaxLength(16);
            entity.Property(e => e.CheckedCount).HasColumnName("checked_count");
            entity.Property(e => e.FixedCount).HasColumnName("fixed_count");
            entity.Property(e => e.ReportedCount).HasColumnName("reported_count");
            entity.Property(e => e.Error).HasColumnName("error");
        });

        modelBuilder.Entity<ReconciliationFinding>(entity =>
        {
            entity.ToTable("reconciliation_findings", t =>
            {
                t.HasCheckConstraint("ck_reconciliation_findings_finding_type", InList("finding_type", FindingType.All));
                t.HasCheckConstraint("ck_reconciliation_findings_action", InList("action", FindingAction.All));
                // Only the types the run fixes can be Düzeltildi; the others are only reported. A fixable type is also
                // Raporlandı when its fix failed.
                t.HasCheckConstraint("ck_reconciliation_findings_fixed_types",
                    $"action <> '{FindingAction.Fixed}' OR ({InList("finding_type", FindingType.Fixable)})");
            });

            entity.HasKey(e => e.Id);
            entity.Property(e => e.Id).HasColumnName("id").UseIdentityAlwaysColumn();
            entity.Property(e => e.RunId).HasColumnName("run_id");
            entity.HasOne<ReconciliationRun>().WithMany().HasForeignKey(e => e.RunId).OnDelete(DeleteBehavior.Restrict);
            // No foreign key to invoices: the ERP may have an invoice the service does not know.
            entity.Property(e => e.InvoiceNumber).HasColumnName("invoice_number").HasMaxLength(64);
            entity.Property(e => e.FindingType).HasColumnName("finding_type").HasMaxLength(32);
            entity.Property(e => e.Action).HasColumnName("action").HasMaxLength(16);
            entity.Property(e => e.Details).HasColumnName("details");
            entity.Property(e => e.CreatedAt).HasColumnName("created_at");
        });
    }

    private static string InList(string column, IEnumerable<string> values) =>
        $"{column} IN ({string.Join(", ", values.Select(v => $"'{v}'"))})";
}
