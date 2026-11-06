using Microsoft.EntityFrameworkCore.Migrations;

#nullable disable

namespace InvoiceService.Infrastructure.Persistence.Migrations
{
    /// <inheritdoc />
    public partial class AddErpVersionSetting : Migration
    {
        /// <inheritdoc />
        protected override void Up(MigrationBuilder migrationBuilder)
        {
            migrationBuilder.Sql("""
                CREATE TABLE erp_version_setting (
                    id integer PRIMARY KEY CHECK (id = 1),
                    v2_percent integer NOT NULL CHECK (v2_percent BETWEEN 0 AND 100)
                );
                INSERT INTO erp_version_setting (id, v2_percent) VALUES (1, 0);
                """);
        }

        /// <inheritdoc />
        protected override void Down(MigrationBuilder migrationBuilder)
        {
            migrationBuilder.Sql("DROP TABLE erp_version_setting;");
        }
    }
}
