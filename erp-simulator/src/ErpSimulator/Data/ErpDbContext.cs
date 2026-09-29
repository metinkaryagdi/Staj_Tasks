using Microsoft.EntityFrameworkCore;

namespace ErpSimulator.Data;

public sealed class ErpDbContext(DbContextOptions<ErpDbContext> options) : DbContext(options)
{
    public DbSet<ErpInvoice> Invoices => Set<ErpInvoice>();

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
    }
}
