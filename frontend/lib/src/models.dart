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

/// A conversation as returned by the list, `created` event, and `GET /{id}`.
class Conversation {
  const Conversation({
    required this.id,
    required this.title,
    this.createdAt,
    this.updatedAt,
  });

  final String id;
  final String title;
  final DateTime? createdAt;

  /// When a message was last added. Drives list ordering; also updated locally
  /// when the user sends a message so the sidebar re-sorts without a refetch.
  final DateTime? updatedAt;

  factory Conversation.fromJson(Map<String, dynamic> json) => Conversation(
    id: json['id'] as String,
    title: (json['title'] as String?) ?? 'Untitled',
    createdAt: DateTime.tryParse('${json['createdAt']}'),
    updatedAt: DateTime.tryParse('${json['updatedAt']}'),
  );

  Conversation copyWith({String? title, DateTime? updatedAt}) => Conversation(
    id: id,
    title: title ?? this.title,
    createdAt: createdAt,
    updatedAt: updatedAt ?? this.updatedAt,
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
