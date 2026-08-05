using Microsoft.EntityFrameworkCore.Migrations;

namespace Tier0.MigrationFixture;

[Migration("20260101000000_CreateAndNullable")]
public sealed class CreateAndNullable : Migration
{
    protected override void Up(MigrationBuilder migrationBuilder)
    {
        migrationBuilder.CreateTable(
            name: "NewTable",
            columns: table => new { Id = table.Column<int>(nullable: false) },
            constraints: table => table.PrimaryKey("PK_NewTable", item => item.Id));
        migrationBuilder.AddColumn<string>(name: "Optional", table: "Existing", nullable: true);
    }

    protected override void Down(MigrationBuilder migrationBuilder) { }
}

[Migration("20260102000000_RiskyKnown")]
public sealed class RiskyKnown : Migration
{
    protected override void Up(MigrationBuilder migrationBuilder)
    {
        migrationBuilder.AddColumn<string>(name: "Required", table: "Existing", nullable: false,
            defaultValue: "backfill");
        migrationBuilder.Sql("UPDATE Existing SET Required = 'backfill'");
    }

    protected override void Down(MigrationBuilder migrationBuilder) { }
}

[Migration("20260103000000_UnknownDefaultsRisky")]
public sealed class UnknownDefaultsRisky : Migration
{
    protected override void Up(MigrationBuilder migrationBuilder)
        => migrationBuilder.EnsureSchema("unexpected");

    protected override void Down(MigrationBuilder migrationBuilder) { }
}
