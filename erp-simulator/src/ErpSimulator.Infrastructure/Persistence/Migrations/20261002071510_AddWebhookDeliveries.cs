using System;
using Microsoft.EntityFrameworkCore.Migrations;
using Npgsql.EntityFrameworkCore.PostgreSQL.Metadata;

#nullable disable

namespace ErpSimulator.Infrastructure.Persistence.Migrations
{
    /// <inheritdoc />
    public partial class AddWebhookDeliveries : Migration
    {
        /// <inheritdoc />
        protected override void Up(MigrationBuilder migrationBuilder)
        {
            migrationBuilder.CreateTable(
                name: "webhook_deliveries",
                columns: table => new
                {
                    id = table.Column<long>(type: "bigint", nullable: false)
                        .Annotation("Npgsql:ValueGenerationStrategy", NpgsqlValueGenerationStrategy.IdentityAlwaysColumn),
                    event_id = table.Column<string>(type: "character varying(64)", maxLength: 64, nullable: false),
                    event_type = table.Column<string>(type: "character varying(32)", maxLength: 32, nullable: false),
                    invoice_id = table.Column<long>(type: "bigint", nullable: false),
                    invoice_number = table.Column<string>(type: "character varying(64)", maxLength: 64, nullable: false),
                    kind = table.Column<string>(type: "character varying(16)", maxLength: 16, nullable: false),
                    payload = table.Column<string>(type: "text", nullable: false),
                    occurred_at = table.Column<DateTimeOffset>(type: "timestamp with time zone", nullable: false),
                    due_at = table.Column<DateTimeOffset>(type: "timestamp with time zone", nullable: false),
                    status = table.Column<string>(type: "character varying(16)", maxLength: 16, nullable: false),
                    attempt_count = table.Column<int>(type: "integer", nullable: false),
                    last_http_status = table.Column<int>(type: "integer", nullable: true),
                    last_error = table.Column<string>(type: "text", nullable: true),
                    created_at = table.Column<DateTimeOffset>(type: "timestamp with time zone", nullable: false),
                    completed_at = table.Column<DateTimeOffset>(type: "timestamp with time zone", nullable: true)
                },
                constraints: table =>
                {
                    table.PrimaryKey("PK_webhook_deliveries", x => x.id);
                    table.CheckConstraint("ck_webhook_deliveries_kind", "kind IN ('Normal')");
                    table.CheckConstraint("ck_webhook_deliveries_status", "status IN ('Pending', 'Delivered', 'Failed', 'Rejected')");
                    table.ForeignKey(
                        name: "FK_webhook_deliveries_invoices_invoice_id",
                        column: x => x.invoice_id,
                        principalTable: "invoices",
                        principalColumn: "id",
                        onDelete: ReferentialAction.Restrict);
                });

            migrationBuilder.CreateIndex(
                name: "IX_webhook_deliveries_event_id",
                table: "webhook_deliveries",
                column: "event_id");

            migrationBuilder.CreateIndex(
                name: "IX_webhook_deliveries_invoice_id",
                table: "webhook_deliveries",
                column: "invoice_id");

            migrationBuilder.CreateIndex(
                name: "IX_webhook_deliveries_invoice_number",
                table: "webhook_deliveries",
                column: "invoice_number");

            migrationBuilder.CreateIndex(
                name: "IX_webhook_deliveries_status_due_at",
                table: "webhook_deliveries",
                columns: new[] { "status", "due_at" });
        }

        /// <inheritdoc />
        protected override void Down(MigrationBuilder migrationBuilder)
        {
            migrationBuilder.DropTable(
                name: "webhook_deliveries");
        }
    }
}
