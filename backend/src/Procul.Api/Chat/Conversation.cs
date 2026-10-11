namespace Procul.Api.Chat;

public class Conversation
{
    public Guid Id { get; set; } = Guid.CreateVersion7();
    public String Title { get; set; } = "New Conversation";
    public DateTimeOffset CreatedAt { get; private set; } = DateTimeOffset.UtcNow;
}