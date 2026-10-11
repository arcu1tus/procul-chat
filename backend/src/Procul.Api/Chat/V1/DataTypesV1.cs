namespace Procul.Api.Chat.V1;

// Versioned request/response DTOs for the v1 conversation endpoints. Serialized as
// camelCase (JsonSerializerDefaults.Web); MessageRole is emitted as the enum ordinal.

/// <summary>A conversation as returned by list, get, and the create stream.</summary>
public sealed record ConversationV1(
    Guid Id,
    string Title,
    DateTimeOffset CreatedAt,
    DateTimeOffset UpdatedAt
);

/// <summary>A single persisted message of a conversation.</summary>
public sealed record ConversationMessageV1(
    Guid Id,
    Guid ConversationId,
    string Text,
    MessageRole MessageRole,
    DateTimeOffset CreatedAt
);

// POST /conversations
public sealed record CreateConversationRequestV1(string InitialMessage);

// GET /conversations
public sealed record GetConversationsResponseV1(List<ConversationV1> Conversations);

// GET /conversations/{conversationId}
public sealed record GetConversationResponseV1(ConversationV1 Conversation);

// PATCH /conversations/{conversationId}
public sealed record RenameConversationRequestV1(string? Title);

// GET /conversations/{conversationId}/messages
public sealed record GetConversationMessagesResponseV1(List<ConversationMessageV1> Messages);

// POST /conversations/{conversationId}/messages
public sealed record SendMessageRequestV1(string Text);
