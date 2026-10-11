using Microsoft.EntityFrameworkCore.Migrations;

#nullable disable

namespace Procul.Api.Migrations
{
    /// <inheritdoc />
    public partial class AddMessageHistoryIndex : Migration
    {
        /// <inheritdoc />
        protected override void Up(MigrationBuilder migrationBuilder)
        {
            migrationBuilder.DropIndex(
                name: "IX_ConversationMessages_ConversationId",
                table: "ConversationMessages");

            migrationBuilder.CreateIndex(
                name: "IX_ConversationMessages_ConversationId_CreatedAt_Id",
                table: "ConversationMessages",
                columns: new[] { "ConversationId", "CreatedAt", "Id" });
        }

        /// <inheritdoc />
        protected override void Down(MigrationBuilder migrationBuilder)
        {
            migrationBuilder.DropIndex(
                name: "IX_ConversationMessages_ConversationId_CreatedAt_Id",
                table: "ConversationMessages");

            migrationBuilder.CreateIndex(
                name: "IX_ConversationMessages_ConversationId",
                table: "ConversationMessages",
                column: "ConversationId");
        }
    }
}
