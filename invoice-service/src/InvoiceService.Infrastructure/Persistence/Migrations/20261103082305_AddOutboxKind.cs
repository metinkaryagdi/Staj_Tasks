using Microsoft.EntityFrameworkCore.Migrations;

#nullable disable

namespace InvoiceService.Infrastructure.Persistence.Migrations
{
    /// <inheritdoc />
    public partial class AddOutboxKind : Migration
    {
        /// <inheritdoc />
        protected override void Up(MigrationBuilder migrationBuilder)
        {
            migrationBuilder.DropCheckConstraint(
                name: "ck_operator_actions_action",
                table: "operator_actions");

            migrationBuilder.DropIndex(
                name: "IX_erp_outbox_invoice_number",
                table: "erp_outbox");

            migrationBuilder.AddColumn<string>(
                name: "kind",
                table: "erp_outbox",
                type: "character varying(16)",
                maxLength: 16,
                nullable: false,
                defaultValue: "Gönderim");

            migrationBuilder.AddCheckConstraint(
                name: "ck_operator_actions_action",
                table: "operator_actions",
                sql: "action IN ('Yeniden Gönderme', 'Toplu Yeniden Gönderme', 'Mutabakat Başlatma', 'Takibe Alma', 'Takibi Kapatma', 'İptal')");

            migrationBuilder.CreateIndex(
                name: "IX_erp_outbox_invoice_number_kind",
                table: "erp_outbox",
                columns: new[] { "invoice_number", "kind" },
                unique: true);

            migrationBuilder.AddCheckConstraint(
                name: "ck_erp_outbox_kind",
                table: "erp_outbox",
                sql: "kind IN ('Gönderim', 'İptal')");
        }

        /// <inheritdoc />
        protected override void Down(MigrationBuilder migrationBuilder)
        {
            migrationBuilder.DropCheckConstraint(
                name: "ck_operator_actions_action",
                table: "operator_actions");

            migrationBuilder.DropIndex(
                name: "IX_erp_outbox_invoice_number_kind",
                table: "erp_outbox");

            migrationBuilder.DropCheckConstraint(
                name: "ck_erp_outbox_kind",
                table: "erp_outbox");

            migrationBuilder.DropColumn(
                name: "kind",
                table: "erp_outbox");

            migrationBuilder.AddCheckConstraint(
                name: "ck_operator_actions_action",
                table: "operator_actions",
                sql: "action IN ('Yeniden Gönderme', 'Toplu Yeniden Gönderme', 'Mutabakat Başlatma', 'Takibe Alma', 'Takibi Kapatma')");

            migrationBuilder.CreateIndex(
                name: "IX_erp_outbox_invoice_number",
                table: "erp_outbox",
                column: "invoice_number",
                unique: true);
        }
    }
}
