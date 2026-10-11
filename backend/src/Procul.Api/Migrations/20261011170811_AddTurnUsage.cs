using System;
using Microsoft.EntityFrameworkCore.Migrations;

#nullable disable

namespace Procul.Api.Migrations
{
    /// <inheritdoc />
    public partial class AddTurnUsage : Migration
    {
        /// <inheritdoc />
        protected override void Up(MigrationBuilder migrationBuilder)
        {
            migrationBuilder.CreateTable(
                name: "TurnUsages",
                columns: table => new
                {
                    Id = table.Column<Guid>(type: "uuid", nullable: false),
                    ConversationId = table.Column<Guid>(type: "uuid", nullable: false),
                    Model = table.Column<string>(type: "character varying(256)", maxLength: 256, nullable: false),
                    Kind = table.Column<string>(type: "character varying(16)", maxLength: 16, nullable: false),
                    InputTokens = table.Column<long>(type: "bigint", nullable: false),
                    OutputTokens = table.Column<long>(type: "bigint", nullable: false),
                    CachedInputTokens = table.Column<long>(type: "bigint", nullable: false),
                    TotalTokens = table.Column<long>(type: "bigint", nullable: false),
                    CreatedAt = table.Column<DateTimeOffset>(type: "timestamp with time zone", nullable: false)
                },
                constraints: table =>
                {
                    table.PrimaryKey("PK_TurnUsages", x => x.Id);
                    table.ForeignKey(
                        name: "FK_TurnUsages_Conversations_ConversationId",
                        column: x => x.ConversationId,
                        principalTable: "Conversations",
                        principalColumn: "Id",
                        onDelete: ReferentialAction.Cascade);
                });

            migrationBuilder.CreateIndex(
                name: "IX_TurnUsages_ConversationId",
                table: "TurnUsages",
                column: "ConversationId");

            migrationBuilder.CreateIndex(
                name: "IX_TurnUsages_CreatedAt",
                table: "TurnUsages",
                column: "CreatedAt");
        }

        /// <inheritdoc />
        protected override void Down(MigrationBuilder migrationBuilder)
        {
            migrationBuilder.DropTable(
                name: "TurnUsages");
        }
    }
}
