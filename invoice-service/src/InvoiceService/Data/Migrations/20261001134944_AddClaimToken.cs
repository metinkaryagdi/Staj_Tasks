using System;
using Microsoft.EntityFrameworkCore.Migrations;

#nullable disable

namespace InvoiceService.Data.Migrations
{
    /// <inheritdoc />
    public partial class AddClaimToken : Migration
    {
        /// <inheritdoc />
        protected override void Up(MigrationBuilder migrationBuilder)
        {
            migrationBuilder.AddColumn<Guid>(
                name: "claim_token",
                table: "erp_outbox",
                type: "uuid",
                nullable: true);
        }

        /// <inheritdoc />
        protected override void Down(MigrationBuilder migrationBuilder)
        {
            migrationBuilder.DropColumn(
                name: "claim_token",
                table: "erp_outbox");
        }
    }
}
