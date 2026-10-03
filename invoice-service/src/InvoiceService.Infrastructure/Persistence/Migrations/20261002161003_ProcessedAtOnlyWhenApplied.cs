using Microsoft.EntityFrameworkCore.Migrations;

#nullable disable

namespace InvoiceService.Infrastructure.Persistence.Migrations
{
    /// <inheritdoc />
    public partial class ProcessedAtOnlyWhenApplied : Migration
    {
        /// <inheritdoc />
        protected override void Up(MigrationBuilder migrationBuilder)
        {
            // Yok Sayıldı events were never applied to the invoice: earlier rows lose the time they were ignored at.
            migrationBuilder.Sql("UPDATE erp_webhook_events SET processed_at = NULL WHERE status = 'Yok Sayıldı';");

            migrationBuilder.AddCheckConstraint(
                name: "ck_erp_webhook_events_processed_at",
                table: "erp_webhook_events",
                sql: "(status = 'İşlendi') = (processed_at IS NOT NULL)");
        }

        /// <inheritdoc />
        protected override void Down(MigrationBuilder migrationBuilder)
        {
            migrationBuilder.DropCheckConstraint(
                name: "ck_erp_webhook_events_processed_at",
                table: "erp_webhook_events");
        }
    }
}
