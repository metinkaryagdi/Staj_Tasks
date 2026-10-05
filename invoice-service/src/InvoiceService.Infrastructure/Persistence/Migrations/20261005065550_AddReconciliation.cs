using System;
using Microsoft.EntityFrameworkCore.Migrations;
using Npgsql.EntityFrameworkCore.PostgreSQL.Metadata;

#nullable disable

namespace InvoiceService.Infrastructure.Persistence.Migrations
{
    /// <inheritdoc />
    public partial class AddReconciliation : Migration
    {
        /// <inheritdoc />
        protected override void Up(MigrationBuilder migrationBuilder)
        {
            migrationBuilder.DropCheckConstraint(
                name: "ck_erp_webhook_events_ignore_reason",
                table: "erp_webhook_events");

            migrationBuilder.CreateTable(
                name: "reconciliation_runs",
                columns: table => new
                {
                    id = table.Column<long>(type: "bigint", nullable: false)
                        .Annotation("Npgsql:ValueGenerationStrategy", NpgsqlValueGenerationStrategy.IdentityAlwaysColumn),
                    started_at = table.Column<DateTimeOffset>(type: "timestamp with time zone", nullable: false),
                    finished_at = table.Column<DateTimeOffset>(type: "timestamp with time zone", nullable: true),
                    status = table.Column<string>(type: "character varying(16)", maxLength: 16, nullable: false),
                    checked_count = table.Column<int>(type: "integer", nullable: false),
                    fixed_count = table.Column<int>(type: "integer", nullable: false),
                    reported_count = table.Column<int>(type: "integer", nullable: false),
                    error = table.Column<string>(type: "text", nullable: true)
                },
                constraints: table =>
                {
                    table.PrimaryKey("PK_reconciliation_runs", x => x.id);
                    table.CheckConstraint("ck_reconciliation_runs_counts", "checked_count >= 0 AND fixed_count >= 0 AND reported_count >= 0");
                    table.CheckConstraint("ck_reconciliation_runs_error", "(status = 'Başarısız') = (error IS NOT NULL)");
                    table.CheckConstraint("ck_reconciliation_runs_finished_at", "(status = 'Çalışıyor') = (finished_at IS NULL)");
                    table.CheckConstraint("ck_reconciliation_runs_status", "status IN ('Çalışıyor', 'Tamamlandı', 'Başarısız')");
                });

            migrationBuilder.CreateTable(
                name: "reconciliation_findings",
                columns: table => new
                {
                    id = table.Column<long>(type: "bigint", nullable: false)
                        .Annotation("Npgsql:ValueGenerationStrategy", NpgsqlValueGenerationStrategy.IdentityAlwaysColumn),
                    run_id = table.Column<long>(type: "bigint", nullable: false),
                    invoice_number = table.Column<string>(type: "character varying(64)", maxLength: 64, nullable: false),
                    finding_type = table.Column<string>(type: "character varying(32)", maxLength: 32, nullable: false),
                    action = table.Column<string>(type: "character varying(16)", maxLength: 16, nullable: false),
                    details = table.Column<string>(type: "text", nullable: false),
                    created_at = table.Column<DateTimeOffset>(type: "timestamp with time zone", nullable: false)
                },
                constraints: table =>
                {
                    table.PrimaryKey("PK_reconciliation_findings", x => x.id);
                    table.CheckConstraint("ck_reconciliation_findings_action", "action IN ('Düzeltildi', 'Raporlandı')");
                    table.CheckConstraint("ck_reconciliation_findings_finding_type", "finding_type IN ('Takılı Fatura', 'Başarısız Ama ERP Kayıtlı', 'Tanınmayan Haber', 'Serviste Yok', 'ERP Kaydı Yok', 'ERP Çift Kayıt', 'Alan Farkı')");
                    table.CheckConstraint("ck_reconciliation_findings_fixed_types", "(action = 'Düzeltildi') = (finding_type IN ('Takılı Fatura', 'Başarısız Ama ERP Kayıtlı', 'Tanınmayan Haber'))");
                    table.ForeignKey(
                        name: "FK_reconciliation_findings_reconciliation_runs_run_id",
                        column: x => x.run_id,
                        principalTable: "reconciliation_runs",
                        principalColumn: "id",
                        onDelete: ReferentialAction.Restrict);
                });

            migrationBuilder.AddCheckConstraint(
                name: "ck_erp_webhook_events_ignore_reason",
                table: "erp_webhook_events",
                sql: "(status = 'Yok Sayıldı') = (ignore_reason IS NOT NULL) AND (ignore_reason IS NULL OR ignore_reason IN ('Geri Götürüyor', 'Kesin Durumda', 'İlerletmiyor', 'Referans Farklı', 'Fatura Yok'))");

            migrationBuilder.CreateIndex(
                name: "IX_reconciliation_findings_run_id",
                table: "reconciliation_findings",
                column: "run_id");
        }

        /// <inheritdoc />
        protected override void Down(MigrationBuilder migrationBuilder)
        {
            migrationBuilder.DropTable(
                name: "reconciliation_findings");

            migrationBuilder.DropTable(
                name: "reconciliation_runs");

            migrationBuilder.DropCheckConstraint(
                name: "ck_erp_webhook_events_ignore_reason",
                table: "erp_webhook_events");

            migrationBuilder.AddCheckConstraint(
                name: "ck_erp_webhook_events_ignore_reason",
                table: "erp_webhook_events",
                sql: "(status = 'Yok Sayıldı') = (ignore_reason IS NOT NULL) AND (ignore_reason IS NULL OR ignore_reason IN ('Geri Götürüyor', 'Kesin Durumda', 'İlerletmiyor', 'Referans Farklı'))");
        }
    }
}
