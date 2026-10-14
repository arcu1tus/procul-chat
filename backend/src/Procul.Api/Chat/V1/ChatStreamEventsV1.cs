namespace Procul.Api.Chat.V1;

using System.Text.Json.Serialization;

// SSE events streamed by the conversation endpoints. The event kind is carried by a `type`
// discriminator inside the JSON payload (the response never emits an SSE `event:` name); the
// `Type` default on each payload supplies it. The hierarchy is serialized polymorphically
// without [JsonDerivedType] — see the gotchas in AGENTS.md.

/// <summary>A newly created conversation. Only emitted by POST /conversations.</summary>
public sealed record ChatStreamCreatedV1(ConversationV1 Conversation, string Type = "created");

/// <summary>The backend accepted the turn.</summary>
public sealed record ChatStreamProcessingV1(string Message, string Type = "acknowledge");

/// <summary>A chunk of the assistant's reply.</summary>
public sealed record ChatStreamReasoningV1(string Content, string Type = "reasoning");

public sealed record ChatStreamTokenV1(string Content, string Type = "token");

/// <summary>The model-generated title for a conversation. Only emitted by create, after the reply.</summary>
public sealed record ChatStreamTitleV1(Guid ConversationId, string Title, string Type = "title");

/// <summary>A tool the model asked to run. <c>Arguments</c> is a JSON object string, or null.</summary>
public sealed record ChatStreamToolCallV1(string CallId, string Name, string? Arguments, string Type = "toolCall");

/// <summary>The outcome of a <c>toolCall</c>. Correlate via <c>CallId</c>; exactly one of
/// <c>Result</c>/<c>Error</c> is typically set.</summary>
public sealed record ChatStreamToolResultV1(string CallId, string? Result, string? Error, string Type = "toolResult");

/// <summary>The turn failed mid-stream.</summary>
public sealed record ChatStreamFailedV1(string Error, string Type = "error");

/// <summary>Token usage for the reply, summed across every underlying model call on the turn.</summary>
public sealed record ChatStreamUsageV1(
    long? InputTokens,
    long? OutputTokens,
    long? CachedInputTokens,
    long? TotalTokens,
    [property: JsonIgnore(Condition = JsonIgnoreCondition.WhenWritingNull)] string? Model = null,
    string Type = "usage");

/// <summary>
/// An image the assistant produced or showed during the turn. Fetch the bytes from the normal
/// attachment route (<c>GET /v1/attachments/{AttachmentId}</c>).
/// </summary>
public sealed record ChatStreamImageV1(
    Guid AttachmentId,
    string? FileName,
    string? ContentType,
    string Type = "image");

/// <summary>The assistant's reply is complete and persisted.</summary>
public sealed record ChatStreamDoneV1(
    [property: JsonIgnore(Condition = JsonIgnoreCondition.WhenWritingNull)] int? Revision = null,
    string Type = "done");

/// <summary>Envelope carried on the wire as <c>{"value": {...}}</c>.</summary>
public abstract record ChatStreamEventV1
{
    public sealed record Created(ChatStreamCreatedV1 Value) : ChatStreamEventV1;
    public sealed record Processing(ChatStreamProcessingV1 Value) : ChatStreamEventV1;
    public sealed record Reasoning(ChatStreamReasoningV1 Value) : ChatStreamEventV1;
    public sealed record Token(ChatStreamTokenV1 Value) : ChatStreamEventV1;
    public sealed record Title(ChatStreamTitleV1 Value) : ChatStreamEventV1;
    public sealed record ToolCall(ChatStreamToolCallV1 Value) : ChatStreamEventV1;
    public sealed record ToolResult(ChatStreamToolResultV1 Value) : ChatStreamEventV1;
    public sealed record Failed(ChatStreamFailedV1 Value) : ChatStreamEventV1;
    public sealed record Usage(ChatStreamUsageV1 Value) : ChatStreamEventV1;
    public sealed record Image(ChatStreamImageV1 Value) : ChatStreamEventV1;
    public sealed record Done(ChatStreamDoneV1 Value) : ChatStreamEventV1;
}
