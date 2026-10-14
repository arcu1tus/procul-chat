namespace Procul.Api.Chat;

/// <summary>Display history of one invocation. Never replayed as a model tool request.</summary>
public sealed class ConversationToolCall
{
    public Guid MessageId { get; set; }
    public int Sequence { get; set; }
    public string CallId { get; set; } = "";
    public string Name { get; set; } = "";
    public string? Arguments { get; set; }
    public string? Result { get; set; }
    public string? Error { get; set; }
    public string Status { get; set; } = "pending";
}
