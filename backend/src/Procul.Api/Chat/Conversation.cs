namespace Procul.Api.Chat;

public class Conversation
{
    public Guid Id { get; set; } = Guid.CreateVersion7();
    public string Title { get; set; } = "New Conversation";
    public DateTimeOffset CreatedAt { get; private set; } = DateTimeOffset.UtcNow;

    /// <summary>Last time a message was added to this conversation. Drives list ordering.</summary>
    public DateTimeOffset UpdatedAt { get; set; } = DateTimeOffset.UtcNow;
}
