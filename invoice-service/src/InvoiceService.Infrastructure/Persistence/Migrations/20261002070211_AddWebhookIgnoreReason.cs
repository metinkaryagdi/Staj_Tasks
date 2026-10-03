using Microsoft.EntityFrameworkCore.Migrations;

#nullable disable

namespace InvoiceService.Infrastructure.Persistence.Migrations
{
    /// <inheritdoc />
    public partial class AddWebhookIgnoreReason : Migration
    {
        /// <inheritdoc />
        protected override void Up(MigrationBuilder migrationBuilder)
        {
            migrationBuilder.AddColumn<string>(
                name: "ignore_reason",
                table: "erp_webhook_events",
                type: "character varying(16)",
                maxLength: 16,
                nullable: true);

            migrationBuilder.AddCheckConstraint(
                name: "ck_erp_webhook_events_ignore_reason",
                table: "erp_webhook_events",
                sql: "(status = 'Yok Sayıldı') = (ignore_reason IS NOT NULL) AND (ignore_reason IS NULL OR ignore_reason IN ('Geri Götürüyor', 'Kesin Durumda', 'İlerletmiyor', 'Referans Farklı'))");
        }

        /// <inheritdoc />
        protected override void Down(MigrationBuilder migrationBuilder)
        {
            migrationBuilder.DropCheckConstraint(
                name: "ck_erp_webhook_events_ignore_reason",
                table: "erp_webhook_events");

            migrationBuilder.DropColumn(
                name: "ignore_reason",
                table: "erp_webhook_events");
        }
    }
}
