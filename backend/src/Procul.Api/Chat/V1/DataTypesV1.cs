using System.Text.Json.Serialization;

namespace Procul.Api.Chat.V1;

// Versioned request/response DTOs for the v1 conversation endpoints. Serialized as
// camelCase (JsonSerializerDefaults.Web); MessageRole is emitted as the enum ordinal.

/// <summary>A conversation as returned by list, get, and the create stream.</summary>
public sealed record ConversationV1(
    Guid Id,
    string Title,
    DateTimeOffset CreatedAt,
    DateTimeOffset UpdatedAt,
    string? Model
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
public sealed record CreateConversationRequestV1(
    string InitialMessage,
    [property: JsonIgnore(Condition = JsonIgnoreCondition.WhenWritingNull)] string? Model = null);

// GET /conversations
public sealed record GetConversationsResponseV1(List<ConversationV1> Conversations);

// GET /conversations/{conversationId}
public sealed record GetConversationResponseV1(ConversationV1 Conversation);

// PATCH /conversations/{conversationId}
public sealed record RenameConversationRequestV1(string? Title);

// PUT /conversations/{conversationId}/model
public sealed record SetConversationModelRequestV1(string Model);

// GET /conversations/{conversationId}/messages
public sealed record GetConversationMessagesResponseV1(List<ConversationMessageV1> Messages);

// POST /conversations/{conversationId}/messages
public sealed record SendMessageRequestV1(string Text);

// GET /models
public sealed record GetModelsResponseV1(string DefaultModel, List<ModelV1> Models);

/// <summary>One model as returned by <c>GET /v1/models</c> (never includes the API key).</summary>
public sealed record ModelV1(
    string Slug,
    string Name,
    string? Description,
    string Provider,
    bool IsDefault,
    ModelCapabilitiesV1 Capabilities,
    ModelHealthV1 Health
);

/// <summary>The resolved input/output modalities of a model.</summary>
public sealed record ModelCapabilitiesV1(List<string> Input, List<string> Output);

/// <summary>A secret-free health snapshot. <c>status</c> and <c>source</c> are lower-case strings.</summary>
public sealed record ModelHealthV1(
    string Status,
    DateTimeOffset? LastCheckedAt,
    long? LatencyMs,
    string? LastError,
    DateTimeOffset? LastUsedAt,
    string? Source
);
