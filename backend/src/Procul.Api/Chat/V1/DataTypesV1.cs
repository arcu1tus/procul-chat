namespace Procul.Api.Chat.V1;

// Data Types
public sealed record ConversationMessageV1
(
    Guid Id,
    Guid ConversationId,
    String Text,
    MessageRole MessageRole,
    DateTimeOffset CreatedAt
);

public sealed record ConversationV1(
    Guid Id,
    String Title,
    DateTimeOffset CreatedAt
);

// CreateConversation POST

public sealed record CreateConversationRequestV1(String InitialMessage);

// GetConversation GET 
public sealed record GetConversationResponseV1(ConversationV1 Conversation);

// GetConversationMessages GET
public sealed record GetConversationMessagesResponsev1(List<ConversationMessageV1> Messages);

// SendMessage POST
public sealed record SendMessageRequestV1(String Text);

// Chat stream events, shared by CreateConversation and SendMessage
public sealed record ChatStreamCreatedV1(ConversationV1 Conversation, String Type = "created");
public sealed record ChatStreamProcessingV1(String Message, String Type = "acknowledge");
public sealed record ChatStreamTokenV1(String Content, String Type = "token");

/// <summary>A tool the model asked to run. <c>Arguments</c> is a JSON object string, or null.</summary>
public sealed record ChatStreamToolCallV1(String CallId, String Name, String? Arguments, String Type = "toolCall");

/// <summary>The outcome of a <c>toolCall</c>. Correlate via <c>CallId</c>; exactly one of
/// <c>Result</c>/<c>Error</c> is typically set.</summary>
public sealed record ChatStreamToolResultV1(String CallId, String? Result, String? Error, String Type = "toolResult");

public sealed record ChatStreamFailedV1(String Error, String Type = "error");
public sealed record ChatStreamDoneV1(String Type = "done");

public abstract record ChatStreamEventV1
{
    public sealed record Created(ChatStreamCreatedV1 Value) : ChatStreamEventV1;
    public sealed record Processing(ChatStreamProcessingV1 Value) : ChatStreamEventV1;
    public sealed record Token(ChatStreamTokenV1 Value) : ChatStreamEventV1;
    public sealed record ToolCall(ChatStreamToolCallV1 Value) : ChatStreamEventV1;
    public sealed record ToolResult(ChatStreamToolResultV1 Value) : ChatStreamEventV1;
    public sealed record Failed(ChatStreamFailedV1 Value) : ChatStreamEventV1;
    public sealed record Done(ChatStreamDoneV1 Value) : ChatStreamEventV1;
}
