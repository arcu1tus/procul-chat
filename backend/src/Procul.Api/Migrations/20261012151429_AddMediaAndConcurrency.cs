using System;
using Microsoft.EntityFrameworkCore.Migrations;

#nullable disable

namespace Procul.Api.Migrations
{
    /// <inheritdoc />
    public partial class AddMediaAndConcurrency : Migration
    {
        /// <inheritdoc />
        protected override void Up(MigrationBuilder migrationBuilder)
        {
            migrationBuilder.AddColumn<Guid>(
                name: "MessageId",
                table: "TurnUsages",
                type: "uuid",
                nullable: true);

            migrationBuilder.AddColumn<int>(
                name: "Revision",
                table: "Conversations",
                type: "integer",
                nullable: false,
                defaultValue: 0);

            migrationBuilder.AddColumn<string>(
                name: "Source",
                table: "Attachments",
                type: "character varying(32)",
                maxLength: 32,
                nullable: false,
                defaultValue: "upload");

            migrationBuilder.CreateIndex(
                name: "IX_TurnUsages_MessageId",
                table: "TurnUsages",
                column: "MessageId");
        }

        /// <inheritdoc />
        protected override void Down(MigrationBuilder migrationBuilder)
        {
            migrationBuilder.DropIndex(
                name: "IX_TurnUsages_MessageId",
                table: "TurnUsages");

            migrationBuilder.DropColumn(
                name: "MessageId",
                table: "TurnUsages");

            migrationBuilder.DropColumn(
                name: "Revision",
                table: "Conversations");

            migrationBuilder.DropColumn(
                name: "Source",
                table: "Attachments");
        }
    }
}
