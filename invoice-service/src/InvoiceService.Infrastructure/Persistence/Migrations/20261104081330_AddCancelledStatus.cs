using Microsoft.EntityFrameworkCore.Migrations;

#nullable disable

namespace InvoiceService.Infrastructure.Persistence.Migrations
{
    /// <inheritdoc />
    public partial class AddCancelledStatus : Migration
    {
        /// <inheritdoc />
        protected override void Up(MigrationBuilder migrationBuilder)
        {
            migrationBuilder.DropCheckConstraint(
                name: "ck_reconciliation_findings_finding_type",
                table: "reconciliation_findings");

            migrationBuilder.DropCheckConstraint(
                name: "ck_reconciliation_findings_fixed_types",
                table: "reconciliation_findings");

            migrationBuilder.DropCheckConstraint(
                name: "ck_invoices_status",
                table: "invoices");

            migrationBuilder.DropCheckConstraint(
                name: "ck_erp_webhook_events_event_type",
                table: "erp_webhook_events");

            migrationBuilder.AddCheckConstraint(
                name: "ck_reconciliation_findings_finding_type",
                table: "reconciliation_findings",
                sql: "finding_type IN ('Takılı Fatura', 'Başarısız Ama ERP Kayıtlı', 'Tanınmayan Haber', 'Serviste Yok', 'ERP Kaydı Yok', 'ERP Çift Kayıt', 'Alan Farkı', 'ERP Karar Vermedi', 'ERP İptal Etmiş', 'Serviste İptal Edilmiş')");

            migrationBuilder.AddCheckConstraint(
                name: "ck_reconciliation_findings_fixed_types",
                table: "reconciliation_findings",
                sql: "action <> 'Düzeltildi' OR (finding_type IN ('Takılı Fatura', 'Başarısız Ama ERP Kayıtlı', 'Tanınmayan Haber', 'ERP İptal Etmiş', 'Serviste İptal Edilmiş'))");

            migrationBuilder.AddCheckConstraint(
                name: "ck_invoices_status",
                table: "invoices",
                sql: "status IN ('Bekliyor', 'Gönderildi', 'İşleme Alındı', 'Onaylandı', 'Reddedildi', 'Başarısız', 'İptal Edildi')");

            migrationBuilder.AddCheckConstraint(
                name: "ck_erp_webhook_events_event_type",
                table: "erp_webhook_events",
                sql: "event_type IN ('invoice.received', 'invoice.approved', 'invoice.rejected', 'invoice.cancelled')");
        }

        /// <inheritdoc />
        protected override void Down(MigrationBuilder migrationBuilder)
        {
            migrationBuilder.DropCheckConstraint(
                name: "ck_reconciliation_findings_finding_type",
                table: "reconciliation_findings");

            migrationBuilder.DropCheckConstraint(
                name: "ck_reconciliation_findings_fixed_types",
                table: "reconciliation_findings");

            migrationBuilder.DropCheckConstraint(
                name: "ck_invoices_status",
                table: "invoices");

            migrationBuilder.DropCheckConstraint(
                name: "ck_erp_webhook_events_event_type",
                table: "erp_webhook_events");

            migrationBuilder.AddCheckConstraint(
                name: "ck_reconciliation_findings_finding_type",
                table: "reconciliation_findings",
                sql: "finding_type IN ('Takılı Fatura', 'Başarısız Ama ERP Kayıtlı', 'Tanınmayan Haber', 'Serviste Yok', 'ERP Kaydı Yok', 'ERP Çift Kayıt', 'Alan Farkı', 'ERP Karar Vermedi')");

            migrationBuilder.AddCheckConstraint(
                name: "ck_reconciliation_findings_fixed_types",
                table: "reconciliation_findings",
                sql: "action <> 'Düzeltildi' OR (finding_type IN ('Takılı Fatura', 'Başarısız Ama ERP Kayıtlı', 'Tanınmayan Haber'))");

            migrationBuilder.AddCheckConstraint(
                name: "ck_invoices_status",
                table: "invoices",
                sql: "status IN ('Bekliyor', 'Gönderildi', 'İşleme Alındı', 'Onaylandı', 'Reddedildi', 'Başarısız')");

            migrationBuilder.AddCheckConstraint(
                name: "ck_erp_webhook_events_event_type",
                table: "erp_webhook_events",
                sql: "event_type IN ('invoice.received', 'invoice.approved', 'invoice.rejected')");
        }
    }
}
