using System;
using Microsoft.EntityFrameworkCore.Migrations;
using Npgsql.EntityFrameworkCore.PostgreSQL.Metadata;

#nullable disable

namespace InvoiceService.Infrastructure.Persistence.Migrations
{
    /// <inheritdoc />
    public partial class AddErpOutbox : Migration
    {
        /// <inheritdoc />
        protected override void Up(MigrationBuilder migrationBuilder)
        {
            migrationBuilder.DropCheckConstraint(
                name: "ck_invoices_status",
                table: "invoices");

            migrationBuilder.CreateTable(
                name: "erp_outbox",
                columns: table => new
                {
                    id = table.Column<long>(type: "bigint", nullable: false)
                        .Annotation("Npgsql:ValueGenerationStrategy", NpgsqlValueGenerationStrategy.IdentityAlwaysColumn),
                    invoice_number = table.Column<string>(type: "character varying(32)", maxLength: 32, nullable: false),
                    status = table.Column<string>(type: "character varying(16)", maxLength: 16, nullable: false),
                    attempt_count = table.Column<int>(type: "integer", nullable: false),
                    next_attempt_at = table.Column<DateTimeOffset>(type: "timestamp with time zone", nullable: false),
                    last_error = table.Column<string>(type: "text", nullable: true),
                    created_at = table.Column<DateTimeOffset>(type: "timestamp with time zone", nullable: false),
                    processed_at = table.Column<DateTimeOffset>(type: "timestamp with time zone", nullable: true),
                    locked_until = table.Column<DateTimeOffset>(type: "timestamp with time zone", nullable: true),
                    locked_by = table.Column<string>(type: "character varying(64)", maxLength: 64, nullable: true)
                },
                constraints: table =>
                {
                    table.PrimaryKey("PK_erp_outbox", x => x.id);
                    table.CheckConstraint("ck_erp_outbox_status", "status IN ('Bekliyor', 'Tamamlandı', 'Başarısız')");
                    table.ForeignKey(
                        name: "FK_erp_outbox_invoices_invoice_number",
                        column: x => x.invoice_number,
                        principalTable: "invoices",
                        principalColumn: "invoice_number",
                        onDelete: ReferentialAction.Restrict);
                });

            migrationBuilder.AddCheckConstraint(
                name: "ck_invoices_status",
                table: "invoices",
                sql: "status IN ('Bekliyor', 'Gönderildi', 'Başarısız')");

            migrationBuilder.CreateIndex(
                name: "IX_erp_outbox_invoice_number",
                table: "erp_outbox",
                column: "invoice_number",
                unique: true);

            migrationBuilder.CreateIndex(
                name: "IX_erp_outbox_status_next_attempt_at",
                table: "erp_outbox",
                columns: new[] { "status", "next_attempt_at" });
        }

        /// <inheritdoc />
        protected override void Down(MigrationBuilder migrationBuilder)
        {
            migrationBuilder.DropTable(
                name: "erp_outbox");

            migrationBuilder.DropCheckConstraint(
                name: "ck_invoices_status",
                table: "invoices");

            migrationBuilder.AddCheckConstraint(
                name: "ck_invoices_status",
                table: "invoices",
                sql: "status IN ('Gönderildi', 'Başarısız')");
        }
    }
}
