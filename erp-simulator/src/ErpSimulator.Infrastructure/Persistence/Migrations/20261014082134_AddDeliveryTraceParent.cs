using Microsoft.EntityFrameworkCore.Migrations;

#nullable disable

namespace ErpSimulator.Infrastructure.Persistence.Migrations
{
    /// <inheritdoc />
    public partial class AddDeliveryTraceParent : Migration
    {
        /// <inheritdoc />
        protected override void Up(MigrationBuilder migrationBuilder)
        {
            migrationBuilder.AddColumn<string>(
                name: "trace_parent",
                table: "webhook_deliveries",
                type: "character varying(55)",
                maxLength: 55,
                nullable: true);
        }

        /// <inheritdoc />
        protected override void Down(MigrationBuilder migrationBuilder)
        {
            migrationBuilder.DropColumn(
                name: "trace_parent",
                table: "webhook_deliveries");
        }
    }
}
