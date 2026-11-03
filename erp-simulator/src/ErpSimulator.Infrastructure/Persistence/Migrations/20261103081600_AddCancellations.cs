using System;
using Microsoft.EntityFrameworkCore.Migrations;
using Npgsql.EntityFrameworkCore.PostgreSQL.Metadata;

#nullable disable

namespace ErpSimulator.Infrastructure.Persistence.Migrations
{
    /// <inheritdoc />
    public partial class AddCancellations : Migration
    {
        /// <inheritdoc />
        protected override void Up(MigrationBuilder migrationBuilder)
        {
            migrationBuilder.CreateSequence(
                name: "cancel_reference_seq");

            migrationBuilder.CreateTable(
                name: "cancellations",
                columns: table => new
                {
                    id = table.Column<long>(type: "bigint", nullable: false)
                        .Annotation("Npgsql:ValueGenerationStrategy", NpgsqlValueGenerationStrategy.IdentityByDefaultColumn),
                    cancel_reference = table.Column<string>(type: "character varying(32)", maxLength: 32, nullable: false, defaultValueSql: "'IPT-' || lpad(nextval('cancel_reference_seq')::text, 8, '0')"),
                    invoice_number = table.Column<string>(type: "character varying(64)", maxLength: 64, nullable: false),
                    cancelled_at = table.Column<DateTimeOffset>(type: "timestamp with time zone", nullable: false)
                },
                constraints: table =>
                {
                    table.PrimaryKey("PK_cancellations", x => x.id);
                });

            migrationBuilder.CreateIndex(
                name: "IX_cancellations_cancel_reference",
                table: "cancellations",
                column: "cancel_reference",
                unique: true);

            migrationBuilder.CreateIndex(
                name: "IX_cancellations_invoice_number",
                table: "cancellations",
                column: "invoice_number",
                unique: true);
        }

        /// <inheritdoc />
        protected override void Down(MigrationBuilder migrationBuilder)
        {
            migrationBuilder.DropTable(
                name: "cancellations");

            migrationBuilder.DropSequence(
                name: "cancel_reference_seq");
        }
    }
}
