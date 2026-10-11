namespace Procul.Api.Chat;

public class ConversationMessage
{
    public Guid Id { get; set; } = Guid.CreateVersion7();
    public Guid ConversationId { get; set; }

    public string Text { get; set; } = "";
    public MessageRole MessageRole { get; set; }
    public DateTimeOffset CreatedAt { get; set; } = DateTimeOffset.UtcNow;
}