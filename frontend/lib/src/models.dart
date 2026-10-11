/// Data types mirroring the backend's v1 API surface.
///
/// The backend serializes with `JsonSerializerDefaults.Web` (camelCase). Notably
/// `MessageRole` is emitted as an **integer** (the C# enum ordinal), not a string.
library;

/// Roles as persisted/serialized by the backend (`Procul.Api.Chat.MessageRole`).
enum MessageRole { system, user, assistant, tool }

/// Maps the backend's integer enum value to a [MessageRole].
///
/// Unknown values fall back to [MessageRole.user] so a future role added to the
/// backend does not crash an older client.
MessageRole messageRoleFromValue(Object? value) {
  final ordinal = value is int ? value : int.tryParse('$value');
  return switch (ordinal) {
    0 => MessageRole.system,
    1 => MessageRole.user,
    2 => MessageRole.assistant,
    3 => MessageRole.tool,
    _ => MessageRole.user,
  };
}

/// A conversation as returned by `POST /v1/conversations` (the `created` event)
/// and `GET /v1/conversations/{id}`.
class Conversation {
  const Conversation({required this.id, required this.title, this.createdAt});

  final String id;
  final String title;
  final DateTime? createdAt;

  factory Conversation.fromJson(Map<String, dynamic> json) => Conversation(
    id: json['id'] as String,
    title: (json['title'] as String?) ?? 'Untitled',
    createdAt: DateTime.tryParse('${json['createdAt']}'),
  );
}

/// A single tool invocation made by the model during an assistant turn.
///
/// Tool activity is streamed but never persisted by the backend, so these only
/// exist for the lifetime of the turn that produced them (a reloaded
/// conversation shows just the final assistant text).
class ToolCall {
  ToolCall({required this.id, required this.name, this.arguments});

  final String id;
  final String name;

  /// The model's arguments as a JSON object string, or null when there were none.
  final String? arguments;

  /// The tool's output once it has run, or null while still pending.
  String? result;

  /// The failure message if the tool threw, or null.
  String? error;

  /// Whether the tool has neither produced a result nor failed yet.
  bool get isPending => result == null && error == null;

  bool get hasFailed => error != null;
}

/// A single chat message held in the client's in-memory buffer.
///
/// [text] is mutable because an assistant message is streamed token-by-token.
class ChatMessage {
  ChatMessage({
    required this.text,
    required this.role,
    this.id,
    this.createdAt,
  });

  final String? id;
  String text;
  final MessageRole role;
  final DateTime? createdAt;

  /// Tool invocations the model made while producing this assistant message.
  /// Empty for every other role and for messages loaded from history.
  final List<ToolCall> toolCalls = [];

  bool get isUser => role == MessageRole.user;

  factory ChatMessage.fromJson(Map<String, dynamic> json) => ChatMessage(
    id: json['id'] as String?,
    text: (json['text'] as String?) ?? '',
    role: messageRoleFromValue(json['messageRole']),
    createdAt: DateTime.tryParse('${json['createdAt']}'),
  );
}

/// Events streamed by the SSE endpoints. The wire shape is
/// `data: {"value":{"type":"...", ...}}` — the discriminator lives inside `value`.
sealed class ChatStreamEvent {
  const ChatStreamEvent();
}

/// `type: "created"` — only emitted by `POST /v1/conversations`.
class CreatedEvent extends ChatStreamEvent {
  const CreatedEvent(this.conversation);
  final Conversation conversation;
}

/// `type: "acknowledge"` — the backend has accepted the turn.
class AcknowledgeEvent extends ChatStreamEvent {
  const AcknowledgeEvent();
}

/// `type: "token"` — a chunk of the assistant's reply.
class TokenEvent extends ChatStreamEvent {
  const TokenEvent(this.content);
  final String content;
}

/// `type: "toolCall"` — the model asked to run a tool.
///
/// Emitted before the tool runs; the matching [ToolResultEvent] carries the same
/// [callId] and arrives once it finishes.
class ToolCallEvent extends ChatStreamEvent {
  const ToolCallEvent({
    required this.callId,
    required this.name,
    this.arguments,
  });

  final String callId;
  final String name;

  /// The model's arguments as a JSON object string, or null when there were none.
  final String? arguments;
}

/// `type: "toolResult"` — a previously requested tool finished.
///
/// Exactly one of [result] (output) or [error] (failure message) is typically set.
class ToolResultEvent extends ChatStreamEvent {
  const ToolResultEvent({required this.callId, this.result, this.error});

  final String callId;
  final String? result;
  final String? error;
}

/// `type: "error"` — the turn failed mid-stream.
class ErrorEvent extends ChatStreamEvent {
  const ErrorEvent(this.error);
  final String error;
}

/// `type: "done"` — the assistant's reply is complete and persisted.
class DoneEvent extends ChatStreamEvent {
  const DoneEvent();
}
