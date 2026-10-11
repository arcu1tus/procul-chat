namespace Procul.Api.Chat;

using Procul.Api.Attachments;

public class ConversationMessage
{
    public Guid Id { get; set; } = Guid.CreateVersion7();
    public Guid ConversationId { get; set; }

    public string Text { get; set; } = "";
    public MessageRole MessageRole { get; set; }
    public DateTimeOffset CreatedAt { get; set; } = DateTimeOffset.UtcNow;

    /// <summary>Files attached to this message (only user messages carry them).</summary>
    public List<Attachment> Attachments { get; set; } = [];
}