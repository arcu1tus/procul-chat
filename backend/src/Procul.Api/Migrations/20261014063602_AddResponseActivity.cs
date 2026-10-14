using System;
using Microsoft.EntityFrameworkCore.Migrations;

#nullable disable

namespace Procul.Api.Migrations
{
    /// <inheritdoc />
    public partial class AddResponseActivity : Migration
    {
        /// <inheritdoc />
        protected override void Up(MigrationBuilder migrationBuilder)
        {
            migrationBuilder.AddColumn<string>(
                name: "Model",
                table: "ConversationMessages",
                type: "text",
                nullable: true);
            migrationBuilder.AddColumn<string>(
                name: "CompletionStatus",
                table: "ConversationMessages",
                type: "text",
                nullable: false,
                defaultValue: "completed");

            migrationBuilder.AddColumn<string>(
                name: "Reasoning",
                table: "ConversationMessages",
                type: "text",
                nullable: true);

            migrationBuilder.CreateTable(
                name: "ConversationToolCall",
                columns: table => new
                {
                    MessageId = table.Column<Guid>(type: "uuid", nullable: false),
                    Sequence = table.Column<int>(type: "integer", nullable: false),
                    CallId = table.Column<string>(type: "text", nullable: false),
                    Name = table.Column<string>(type: "text", nullable: false),
                    Arguments = table.Column<string>(type: "text", nullable: true),
                    Result = table.Column<string>(type: "text", nullable: true),
                    Error = table.Column<string>(type: "text", nullable: true),
                    Status = table.Column<string>(type: "text", nullable: false)
                },
                constraints: table =>
                {
                    table.PrimaryKey("PK_ConversationToolCall", x => new { x.MessageId, x.Sequence });
                    table.ForeignKey(
                        name: "FK_ConversationToolCall_ConversationMessages_MessageId",
                        column: x => x.MessageId,
                        principalTable: "ConversationMessages",
                        principalColumn: "Id",
                        onDelete: ReferentialAction.Cascade);
                });
        }

        /// <inheritdoc />
        protected override void Down(MigrationBuilder migrationBuilder)
        {
            migrationBuilder.DropColumn(
                name: "Model",
                table: "ConversationMessages");
            migrationBuilder.DropTable(
                name: "ConversationToolCall");

            migrationBuilder.DropColumn(
                name: "CompletionStatus",
                table: "ConversationMessages");

            migrationBuilder.DropColumn(
                name: "Reasoning",
                table: "ConversationMessages");
        }
    }
}
