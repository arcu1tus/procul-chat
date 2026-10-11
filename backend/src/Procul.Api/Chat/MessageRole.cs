using Microsoft.Extensions.AI;

namespace Procul.Api.Chat;

public enum MessageRole
{
    System,
    User,
    Assistant,
    Tool
}

internal static class MessageRoleExtensions
{
    public static ChatRole ToChatRole(this MessageRole role) =>
        role switch
        {
            MessageRole.System => ChatRole.System,
            MessageRole.User => ChatRole.User,
            MessageRole.Assistant => ChatRole.Assistant,
            MessageRole.Tool => ChatRole.Tool,
            _ => throw new ArgumentOutOfRangeException(nameof(role), role, null)
        };
}
