using Microsoft.EntityFrameworkCore.Migrations;

#nullable disable

namespace ErpSimulator.Data.Migrations
{
    /// <inheritdoc />
    public partial class AddWaitingStatus : Migration
    {
        /// <inheritdoc />
        protected override void Up(MigrationBuilder migrationBuilder)
        {
            migrationBuilder.DropCheckConstraint(
                name: "ck_webhook_deliveries_status",
                table: "webhook_deliveries");

            migrationBuilder.AddCheckConstraint(
                name: "ck_webhook_deliveries_status",
                table: "webhook_deliveries",
                sql: "status IN ('Pending', 'Waiting', 'Delivered', 'Failed', 'Rejected', 'Skipped')");
        }

        /// <inheritdoc />
        protected override void Down(MigrationBuilder migrationBuilder)
        {
            migrationBuilder.DropCheckConstraint(
                name: "ck_webhook_deliveries_status",
                table: "webhook_deliveries");

            migrationBuilder.AddCheckConstraint(
                name: "ck_webhook_deliveries_status",
                table: "webhook_deliveries",
                sql: "status IN ('Pending', 'Delivered', 'Failed', 'Rejected', 'Skipped')");
        }
    }
}
