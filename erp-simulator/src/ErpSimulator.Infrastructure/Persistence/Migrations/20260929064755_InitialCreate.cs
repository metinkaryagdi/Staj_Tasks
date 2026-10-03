using System;
using Microsoft.EntityFrameworkCore.Migrations;
using Npgsql.EntityFrameworkCore.PostgreSQL.Metadata;

#nullable disable

namespace ErpSimulator.Infrastructure.Persistence.Migrations
{
    /// <inheritdoc />
    public partial class InitialCreate : Migration
    {
        /// <inheritdoc />
        protected override void Up(MigrationBuilder migrationBuilder)
        {
            migrationBuilder.CreateSequence(
                name: "erp_reference_seq");

            migrationBuilder.CreateTable(
                name: "invoices",
                columns: table => new
                {
                    id = table.Column<long>(type: "bigint", nullable: false)
                        .Annotation("Npgsql:ValueGenerationStrategy", NpgsqlValueGenerationStrategy.IdentityByDefaultColumn),
                    erp_reference = table.Column<string>(type: "character varying(32)", maxLength: 32, nullable: false, defaultValueSql: "'ERP-' || lpad(nextval('erp_reference_seq')::text, 8, '0')"),
                    invoice_number = table.Column<string>(type: "character varying(64)", maxLength: 64, nullable: false),
                    customer_code = table.Column<string>(type: "character varying(64)", maxLength: 64, nullable: false),
                    amount = table.Column<decimal>(type: "numeric(18,2)", precision: 18, scale: 2, nullable: false),
                    currency = table.Column<string>(type: "character(3)", fixedLength: true, maxLength: 3, nullable: false),
                    invoice_date = table.Column<DateOnly>(type: "date", nullable: false),
                    received_at = table.Column<DateTimeOffset>(type: "timestamp with time zone", nullable: false),
                    behavior = table.Column<string>(type: "character varying(32)", maxLength: 32, nullable: false),
                    request_sequence = table.Column<long>(type: "bigint", nullable: false)
                },
                constraints: table =>
                {
                    table.PrimaryKey("PK_invoices", x => x.id);
                });

            migrationBuilder.CreateIndex(
                name: "IX_invoices_erp_reference",
                table: "invoices",
                column: "erp_reference",
                unique: true);

            migrationBuilder.CreateIndex(
                name: "IX_invoices_invoice_number",
                table: "invoices",
                column: "invoice_number");
        }

        /// <inheritdoc />
        protected override void Down(MigrationBuilder migrationBuilder)
        {
            migrationBuilder.DropTable(
                name: "invoices");

            migrationBuilder.DropSequence(
                name: "erp_reference_seq");
        }
    }
}
