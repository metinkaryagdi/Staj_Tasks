using System;
using Microsoft.EntityFrameworkCore.Migrations;
using Npgsql.EntityFrameworkCore.PostgreSQL.Metadata;

#nullable disable

namespace InvoiceService.Infrastructure.Persistence.Migrations
{
    /// <inheritdoc />
    public partial class AddInvoiceFollowUps : Migration
    {
        /// <inheritdoc />
        protected override void Up(MigrationBuilder migrationBuilder)
        {
            migrationBuilder.DropCheckConstraint(
                name: "ck_operator_actions_action",
                table: "operator_actions");

            migrationBuilder.CreateTable(
                name: "invoice_follow_ups",
                columns: table => new
                {
                    id = table.Column<long>(type: "bigint", nullable: false)
                        .Annotation("Npgsql:ValueGenerationStrategy", NpgsqlValueGenerationStrategy.IdentityAlwaysColumn),
                    invoice_number = table.Column<string>(type: "character varying(32)", maxLength: 32, nullable: false),
                    operator_name = table.Column<string>(type: "character varying(100)", maxLength: 100, nullable: false),
                    note = table.Column<string>(type: "character varying(500)", maxLength: 500, nullable: false),
                    opened_at = table.Column<DateTimeOffset>(type: "timestamp with time zone", nullable: false),
                    closed_at = table.Column<DateTimeOffset>(type: "timestamp with time zone", nullable: true),
                    closed_by = table.Column<string>(type: "character varying(100)", maxLength: 100, nullable: true)
                },
                constraints: table =>
                {
                    table.PrimaryKey("PK_invoice_follow_ups", x => x.id);
                    table.CheckConstraint("ck_invoice_follow_ups_closed_by", "(closed_at IS NULL) = (closed_by IS NULL)");
                    table.CheckConstraint("ck_invoice_follow_ups_note", "btrim(note) <> ''");
                    table.CheckConstraint("ck_invoice_follow_ups_operator_name", "btrim(operator_name) <> ''");
                    table.ForeignKey(
                        name: "FK_invoice_follow_ups_invoices_invoice_number",
                        column: x => x.invoice_number,
                        principalTable: "invoices",
                        principalColumn: "invoice_number",
                        onDelete: ReferentialAction.Restrict);
                });

            migrationBuilder.AddCheckConstraint(
                name: "ck_operator_actions_action",
                table: "operator_actions",
                sql: "action IN ('Yeniden Gönderme', 'Toplu Yeniden Gönderme', 'Mutabakat Başlatma', 'Takibe Alma', 'Takibi Kapatma')");

            migrationBuilder.CreateIndex(
                name: "IX_invoice_follow_ups_invoice_number",
                table: "invoice_follow_ups",
                column: "invoice_number",
                unique: true,
                filter: "closed_at IS NULL");
        }

        /// <inheritdoc />
        protected override void Down(MigrationBuilder migrationBuilder)
        {
            migrationBuilder.DropTable(
                name: "invoice_follow_ups");

            migrationBuilder.DropCheckConstraint(
                name: "ck_operator_actions_action",
                table: "operator_actions");

            migrationBuilder.AddCheckConstraint(
                name: "ck_operator_actions_action",
                table: "operator_actions",
                sql: "action IN ('Yeniden Gönderme', 'Toplu Yeniden Gönderme', 'Mutabakat Başlatma')");
        }
    }
}
