namespace Procul.Api.Chat;

/// <summary>Which model call produced a usage row on a turn.</summary>
public enum TurnKind
{
    /// <summary>The assistant reply the user is waiting for.</summary>
    Chat,

    /// <summary>The small, concurrent call that generates a conversation title.</summary>
    Title,
}

/// <summary>
/// One model call's token usage, persisted so usage survives restarts. A single conversation
/// turn can produce more than one row: the reply (<see cref="TurnKind.Chat"/>, which may itself
/// cover several underlying calls when function invocation loops) plus the title
/// (<see cref="TurnKind.Title"/>). Counts come from <c>UsageContent</c> on the response stream.
/// </summary>
public class TurnUsage
{
    public Guid Id { get; set; } = Guid.CreateVersion7();
    public Guid ConversationId { get; set; }

    /// <summary>The OpenRouter model slug that produced these tokens.</summary>
    public string Model { get; set; } = "";

    public TurnKind Kind { get; set; }

    public long InputTokens { get; set; }
    public long OutputTokens { get; set; }
    public long CachedInputTokens { get; set; }
    public long TotalTokens { get; set; }

    public DateTimeOffset CreatedAt { get; set; } = DateTimeOffset.UtcNow;
}
