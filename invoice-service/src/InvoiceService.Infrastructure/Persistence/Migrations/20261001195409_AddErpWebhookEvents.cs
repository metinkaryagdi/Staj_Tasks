using System;
using Microsoft.EntityFrameworkCore.Migrations;

#nullable disable

namespace InvoiceService.Infrastructure.Persistence.Migrations
{
    /// <inheritdoc />
    public partial class AddErpWebhookEvents : Migration
    {
        /// <inheritdoc />
        protected override void Up(MigrationBuilder migrationBuilder)
        {
            migrationBuilder.DropCheckConstraint(
                name: "ck_invoices_status",
                table: "invoices");

            migrationBuilder.AddColumn<string>(
                name: "reject_reason",
                table: "invoices",
                type: "text",
                nullable: true);

            migrationBuilder.CreateTable(
                name: "erp_webhook_events",
                columns: table => new
                {
                    event_id = table.Column<string>(type: "character varying(64)", maxLength: 64, nullable: false),
                    event_type = table.Column<string>(type: "character varying(32)", maxLength: 32, nullable: false),
                    invoice_number = table.Column<string>(type: "character varying(32)", maxLength: 32, nullable: false),
                    erp_reference = table.Column<string>(type: "character varying(32)", maxLength: 32, nullable: false),
                    occurred_at = table.Column<DateTimeOffset>(type: "timestamp with time zone", nullable: false),
                    received_at = table.Column<DateTimeOffset>(type: "timestamp with time zone", nullable: false),
                    processed_at = table.Column<DateTimeOffset>(type: "timestamp with time zone", nullable: true),
                    status = table.Column<string>(type: "character varying(16)", maxLength: 16, nullable: false),
                    payload = table.Column<string>(type: "text", nullable: false),
                    delivery_count = table.Column<int>(type: "integer", nullable: false, defaultValue: 1)
                },
                constraints: table =>
                {
                    table.PrimaryKey("PK_erp_webhook_events", x => x.event_id);
                    table.CheckConstraint("ck_erp_webhook_events_delivery_count", "delivery_count >= 1");
                    table.CheckConstraint("ck_erp_webhook_events_event_type", "event_type IN ('invoice.received', 'invoice.approved', 'invoice.rejected')");
                    table.CheckConstraint("ck_erp_webhook_events_status", "status IN ('İşlendi', 'Bekliyor', 'Yok Sayıldı')");
                });

            migrationBuilder.AddCheckConstraint(
                name: "ck_invoices_status",
                table: "invoices",
                sql: "status IN ('Bekliyor', 'Gönderildi', 'İşleme Alındı', 'Onaylandı', 'Reddedildi', 'Başarısız')");

            migrationBuilder.CreateIndex(
                name: "IX_erp_webhook_events_invoice_number_status",
                table: "erp_webhook_events",
                columns: new[] { "invoice_number", "status" });
        }

        /// <inheritdoc />
        protected override void Down(MigrationBuilder migrationBuilder)
        {
            migrationBuilder.DropTable(
                name: "erp_webhook_events");

            migrationBuilder.DropCheckConstraint(
                name: "ck_invoices_status",
                table: "invoices");

            migrationBuilder.DropColumn(
                name: "reject_reason",
                table: "invoices");

            migrationBuilder.AddCheckConstraint(
                name: "ck_invoices_status",
                table: "invoices",
                sql: "status IN ('Bekliyor', 'Gönderildi', 'Başarısız')");
        }
    }
}
