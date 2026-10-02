using Microsoft.EntityFrameworkCore.Migrations;

#nullable disable

namespace ErpSimulator.Data.Migrations
{
    /// <inheritdoc />
    public partial class WebhookProblems : Migration
    {
        /// <inheritdoc />
        protected override void Up(MigrationBuilder migrationBuilder)
        {
            migrationBuilder.DropCheckConstraint(
                name: "ck_webhook_deliveries_kind",
                table: "webhook_deliveries");

            migrationBuilder.DropCheckConstraint(
                name: "ck_webhook_deliveries_status",
                table: "webhook_deliveries");

            migrationBuilder.AddCheckConstraint(
                name: "ck_webhook_deliveries_kind",
                table: "webhook_deliveries",
                sql: "kind IN ('Normal', 'Duplicate', 'LostDecision', 'Fake', 'Replay')");

            migrationBuilder.AddCheckConstraint(
                name: "ck_webhook_deliveries_status",
                table: "webhook_deliveries",
                sql: "status IN ('Pending', 'Delivered', 'Failed', 'Rejected', 'Skipped')");
        }

        /// <inheritdoc />
        protected override void Down(MigrationBuilder migrationBuilder)
        {
            migrationBuilder.DropCheckConstraint(
                name: "ck_webhook_deliveries_kind",
                table: "webhook_deliveries");

            migrationBuilder.DropCheckConstraint(
                name: "ck_webhook_deliveries_status",
                table: "webhook_deliveries");

            migrationBuilder.AddCheckConstraint(
                name: "ck_webhook_deliveries_kind",
                table: "webhook_deliveries",
                sql: "kind IN ('Normal')");

            migrationBuilder.AddCheckConstraint(
                name: "ck_webhook_deliveries_status",
                table: "webhook_deliveries",
                sql: "status IN ('Pending', 'Delivered', 'Failed', 'Rejected')");
        }
    }
}
