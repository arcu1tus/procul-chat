using System;
using Microsoft.EntityFrameworkCore.Migrations;

#nullable disable

namespace Procul.Api.Migrations
{
    /// <inheritdoc />
    public partial class AddConversationUpdatedAt : Migration
    {
        /// <inheritdoc />
        protected override void Up(MigrationBuilder migrationBuilder)
        {
            migrationBuilder.AddColumn<DateTimeOffset>(
                name: "UpdatedAt",
                table: "Conversations",
                type: "timestamp with time zone",
                nullable: false,
                defaultValue: new DateTimeOffset(new DateTime(1, 1, 1, 0, 0, 0, 0, DateTimeKind.Unspecified), new TimeSpan(0, 0, 0, 0, 0)));

            // Backfill pre-existing conversations so they order by when they were created
            // instead of by the epoch default.
            migrationBuilder.Sql("UPDATE \"Conversations\" SET \"UpdatedAt\" = \"CreatedAt\";");
        }

        /// <inheritdoc />
        protected override void Down(MigrationBuilder migrationBuilder)
        {
            migrationBuilder.DropColumn(
                name: "UpdatedAt",
                table: "Conversations");
        }
    }
}
