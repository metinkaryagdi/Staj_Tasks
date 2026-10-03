using System;
using Microsoft.EntityFrameworkCore.Migrations;

#nullable disable

namespace ErpSimulator.Infrastructure.Persistence.Migrations
{
    /// <inheritdoc />
    public partial class AddFirstSentAt : Migration
    {
        /// <inheritdoc />
        protected override void Up(MigrationBuilder migrationBuilder)
        {
            migrationBuilder.AddColumn<DateTimeOffset>(
                name: "first_sent_at",
                table: "webhook_deliveries",
                type: "timestamp with time zone",
                nullable: true);
        }

        /// <inheritdoc />
        protected override void Down(MigrationBuilder migrationBuilder)
        {
            migrationBuilder.DropColumn(
                name: "first_sent_at",
                table: "webhook_deliveries");
        }
    }
}
