namespace Procul.Api.Chat;

using Procul.Api.Attachments;

public class ConversationMessage
{
    public Guid Id { get; set; } = Guid.CreateVersion7();
    public Guid ConversationId { get; set; }

    public string Text { get; set; } = "";
    public string? Reasoning { get; set; }
    public string? Model { get; set; }
    public string CompletionStatus { get; set; } = "completed";
    public List<ConversationToolCall> ToolCalls { get; set; } = [];
    public MessageRole MessageRole { get; set; }
    public DateTimeOffset CreatedAt { get; set; } = DateTimeOffset.UtcNow;

    /// <summary>Uploaded user files or media produced by assistant tools.</summary>
    public List<Attachment> Attachments { get; set; } = [];
}
