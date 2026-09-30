using System;
using Microsoft.EntityFrameworkCore.Migrations;

#nullable disable

namespace InvoiceService.Data.Migrations
{
    /// <inheritdoc />
    public partial class InitialCreate : Migration
    {
        /// <inheritdoc />
        protected override void Up(MigrationBuilder migrationBuilder)
        {
            migrationBuilder.CreateSequence(
                name: "invoice_number_seq");

            migrationBuilder.CreateTable(
                name: "invoices",
                columns: table => new
                {
                    invoice_number = table.Column<string>(type: "character varying(32)", maxLength: 32, nullable: false),
                    customer_code = table.Column<string>(type: "character varying(64)", maxLength: 64, nullable: false),
                    amount = table.Column<decimal>(type: "numeric(18,2)", precision: 18, scale: 2, nullable: false),
                    currency = table.Column<string>(type: "character(3)", fixedLength: true, maxLength: 3, nullable: false),
                    invoice_date = table.Column<DateOnly>(type: "date", nullable: false),
                    status = table.Column<string>(type: "character varying(16)", maxLength: 16, nullable: false),
                    erp_reference = table.Column<string>(type: "character varying(32)", maxLength: 32, nullable: true),
                    last_error = table.Column<string>(type: "text", nullable: true),
                    send_attempt_count = table.Column<int>(type: "integer", nullable: false),
                    created_at = table.Column<DateTimeOffset>(type: "timestamp with time zone", nullable: false),
                    updated_at = table.Column<DateTimeOffset>(type: "timestamp with time zone", nullable: false)
                },
                constraints: table =>
                {
                    table.PrimaryKey("PK_invoices", x => x.invoice_number);
                    table.CheckConstraint("ck_invoices_currency", "currency ~ '^[A-Z]{3}$'");
                    table.CheckConstraint("ck_invoices_status", "status IN ('Gönderildi', 'Başarısız')");
                });
        }

        /// <inheritdoc />
        protected override void Down(MigrationBuilder migrationBuilder)
        {
            migrationBuilder.DropTable(
                name: "invoices");

            migrationBuilder.DropSequence(
                name: "invoice_number_seq");
        }
    }
}
