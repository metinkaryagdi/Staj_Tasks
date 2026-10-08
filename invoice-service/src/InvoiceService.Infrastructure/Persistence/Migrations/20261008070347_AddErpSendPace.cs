using Microsoft.EntityFrameworkCore.Migrations;

#nullable disable

namespace InvoiceService.Infrastructure.Persistence.Migrations
{
    /// <inheritdoc />
    public partial class AddErpSendPace : Migration
    {
        /// <inheritdoc />
        protected override void Up(MigrationBuilder migrationBuilder)
        {
            // One row: the next free turn for an invoice POST (PostgresSendPacer); not in the EF model.
            migrationBuilder.Sql("""
                CREATE TABLE erp_send_pace (
                    id integer PRIMARY KEY CHECK (id = 1),
                    next_turn_at timestamp with time zone NOT NULL
                );
                INSERT INTO erp_send_pace (id, next_turn_at) VALUES (1, now());
                """);
        }

        /// <inheritdoc />
        protected override void Down(MigrationBuilder migrationBuilder)
        {
            migrationBuilder.Sql("DROP TABLE erp_send_pace;");
        }
    }
}
