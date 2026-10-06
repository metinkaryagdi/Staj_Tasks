using Microsoft.EntityFrameworkCore.Migrations;

#nullable disable

namespace InvoiceService.Infrastructure.Persistence.Migrations
{
    /// <inheritdoc />
    public partial class RelaxFixedFindingTypes : Migration
    {
        /// <inheritdoc />
        protected override void Up(MigrationBuilder migrationBuilder)
        {
            migrationBuilder.DropCheckConstraint(
                name: "ck_reconciliation_findings_fixed_types",
                table: "reconciliation_findings");

            migrationBuilder.AddCheckConstraint(
                name: "ck_reconciliation_findings_fixed_types",
                table: "reconciliation_findings",
                sql: "action <> 'Düzeltildi' OR (finding_type IN ('Takılı Fatura', 'Başarısız Ama ERP Kayıtlı', 'Tanınmayan Haber'))");
        }

        /// <inheritdoc />
        protected override void Down(MigrationBuilder migrationBuilder)
        {
            migrationBuilder.DropCheckConstraint(
                name: "ck_reconciliation_findings_fixed_types",
                table: "reconciliation_findings");

            migrationBuilder.AddCheckConstraint(
                name: "ck_reconciliation_findings_fixed_types",
                table: "reconciliation_findings",
                sql: "(action = 'Düzeltildi') = (finding_type IN ('Takılı Fatura', 'Başarısız Ama ERP Kayıtlı', 'Tanınmayan Haber'))");
        }
    }
}
