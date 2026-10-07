using System;
using Microsoft.EntityFrameworkCore.Migrations;
using Npgsql.EntityFrameworkCore.PostgreSQL.Metadata;

#nullable disable

namespace InvoiceService.Infrastructure.Persistence.Migrations
{
    /// <inheritdoc />
    public partial class AddOperatorActions : Migration
    {
        /// <inheritdoc />
        protected override void Up(MigrationBuilder migrationBuilder)
        {
            migrationBuilder.AddColumn<string>(
                name: "started_by",
                table: "reconciliation_runs",
                type: "character varying(100)",
                maxLength: 100,
                nullable: true);

            migrationBuilder.CreateTable(
                name: "operator_actions",
                columns: table => new
                {
                    id = table.Column<long>(type: "bigint", nullable: false)
                        .Annotation("Npgsql:ValueGenerationStrategy", NpgsqlValueGenerationStrategy.IdentityAlwaysColumn),
                    operator_name = table.Column<string>(type: "character varying(100)", maxLength: 100, nullable: false),
                    action = table.Column<string>(type: "character varying(32)", maxLength: 32, nullable: false),
                    invoice_number = table.Column<string>(type: "character varying(64)", maxLength: 64, nullable: true),
                    result = table.Column<string>(type: "character varying(128)", maxLength: 128, nullable: false),
                    created_at = table.Column<DateTimeOffset>(type: "timestamp with time zone", nullable: false)
                },
                constraints: table =>
                {
                    table.PrimaryKey("PK_operator_actions", x => x.id);
                    table.CheckConstraint("ck_operator_actions_action", "action IN ('Yeniden Gönderme', 'Toplu Yeniden Gönderme', 'Mutabakat Başlatma')");
                    table.CheckConstraint("ck_operator_actions_invoice_number", "(action = 'Mutabakat Başlatma') = (invoice_number IS NULL)");
                    table.CheckConstraint("ck_operator_actions_operator_name", "btrim(operator_name) <> ''");
                });

            migrationBuilder.CreateIndex(
                name: "IX_operator_actions_invoice_number_id",
                table: "operator_actions",
                columns: new[] { "invoice_number", "id" });
        }

        /// <inheritdoc />
        protected override void Down(MigrationBuilder migrationBuilder)
        {
            migrationBuilder.DropTable(
                name: "operator_actions");

            migrationBuilder.DropColumn(
                name: "started_by",
                table: "reconciliation_runs");
        }
    }
}
