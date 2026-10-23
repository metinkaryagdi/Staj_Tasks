using Microsoft.EntityFrameworkCore.Migrations;

#nullable disable

namespace InvoiceService.Infrastructure.Persistence.Migrations
{
    /// <inheritdoc />
    public partial class AddOperatorSub : Migration
    {
        /// <inheritdoc />
        protected override void Up(MigrationBuilder migrationBuilder)
        {
            migrationBuilder.AddColumn<string>(
                name: "started_by_sub",
                table: "reconciliation_runs",
                type: "text",
                nullable: true);

            migrationBuilder.AddColumn<string>(
                name: "operator_sub",
                table: "operator_actions",
                type: "text",
                nullable: true);

            migrationBuilder.AddColumn<string>(
                name: "closed_by_sub",
                table: "invoice_follow_ups",
                type: "text",
                nullable: true);

            migrationBuilder.AddColumn<string>(
                name: "operator_sub",
                table: "invoice_follow_ups",
                type: "text",
                nullable: true);
        }

        /// <inheritdoc />
        protected override void Down(MigrationBuilder migrationBuilder)
        {
            migrationBuilder.DropColumn(
                name: "started_by_sub",
                table: "reconciliation_runs");

            migrationBuilder.DropColumn(
                name: "operator_sub",
                table: "operator_actions");

            migrationBuilder.DropColumn(
                name: "closed_by_sub",
                table: "invoice_follow_ups");

            migrationBuilder.DropColumn(
                name: "operator_sub",
                table: "invoice_follow_ups");
        }
    }
}
