using Microsoft.EntityFrameworkCore.Migrations;

#nullable disable

namespace InvoiceService.Infrastructure.Persistence.Migrations
{
    /// <inheritdoc />
    public partial class AddNoErpDecisionFinding : Migration
    {
        /// <inheritdoc />
        protected override void Up(MigrationBuilder migrationBuilder)
        {
            migrationBuilder.DropCheckConstraint(
                name: "ck_reconciliation_findings_finding_type",
                table: "reconciliation_findings");

            migrationBuilder.AddCheckConstraint(
                name: "ck_reconciliation_findings_finding_type",
                table: "reconciliation_findings",
                sql: "finding_type IN ('Takılı Fatura', 'Başarısız Ama ERP Kayıtlı', 'Tanınmayan Haber', 'Serviste Yok', 'ERP Kaydı Yok', 'ERP Çift Kayıt', 'Alan Farkı', 'ERP Karar Vermedi')");
        }

        /// <inheritdoc />
        protected override void Down(MigrationBuilder migrationBuilder)
        {
            migrationBuilder.DropCheckConstraint(
                name: "ck_reconciliation_findings_finding_type",
                table: "reconciliation_findings");

            migrationBuilder.AddCheckConstraint(
                name: "ck_reconciliation_findings_finding_type",
                table: "reconciliation_findings",
                sql: "finding_type IN ('Takılı Fatura', 'Başarısız Ama ERP Kayıtlı', 'Tanınmayan Haber', 'Serviste Yok', 'ERP Kaydı Yok', 'ERP Çift Kayıt', 'Alan Farkı')");
        }
    }
}
