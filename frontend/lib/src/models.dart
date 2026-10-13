/// Data types mirroring the backend's v1 API surface.
///
/// The backend serializes with `JsonSerializerDefaults.Web` (camelCase). Notably
/// `MessageRole` is emitted as an **integer** (the C# enum ordinal), not a string.
library;

import 'attachments.dart';

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
    this.model,
    this.createdAt,
    this.updatedAt,
    this.revision,
  });

  final String id;
  final String title;

  /// The model slug this conversation uses, or null to fall back to the
  /// configured default.
  final String? model;

  final DateTime? createdAt;

  /// When a message was last added. Drives list ordering; also updated locally
  /// when the user sends a message so the sidebar re-sorts without a refetch.
  final DateTime? updatedAt;

  /// Optimistic-concurrency revision from the backend, echoed back as
  /// `expectedRevision` on every mutation. Null on older backends that do not
  /// send it (in which case no conflict check is possible).
  final int? revision;

  factory Conversation.fromJson(Map<String, dynamic> json) => Conversation(
    id: json['id'] as String,
    title: (json['title'] as String?) ?? 'Untitled',
    model: json['model'] as String?,
    createdAt: DateTime.tryParse('${json['createdAt']}'),
    updatedAt: DateTime.tryParse('${json['updatedAt']}'),
    revision: (json['revision'] as num?)?.toInt(),
  );

  Conversation copyWith({
    String? title,
    String? model,
    DateTime? updatedAt,
    int? revision,
  }) => Conversation(
    id: id,
    title: title ?? this.title,
    model: model ?? this.model,
    createdAt: createdAt,
    updatedAt: updatedAt ?? this.updatedAt,
    revision: revision ?? this.revision,
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
    this.model,
    this.usage,
    List<Attachment> attachments = const [],
  }) : attachments = List.of(attachments);

  String? id;
  String text;
  final MessageRole role;
  final DateTime? createdAt;

  /// The model that produced this (assistant) message, when known.
  ///
  /// Set live from [ChatController.activeModel] when the turn's `usage` event
  /// arrives; populated from history once the backend stores per-message
  /// metadata (PLAN 2 §B4). Null for user messages and unknown history.
  String? model;

  /// This response's token usage, when known (live turn, or history after §B4).
  TokenUsage? usage;

  /// Files attached to this (user) message; empty for every other role.
  ///
  /// A mutable list (not `List.unmodifiable`) so an edit can replace the attachments while
  /// preserving the object's identity — which keeps the entrance-animation tracking in
  /// `ChatScreen` stable across the change.
  final List<Attachment> attachments;

  /// Tool invocations the model made while producing this assistant message.
  /// Empty for every other role and for messages loaded from history.
  final List<ToolCall> toolCalls = [];

  bool get isUser => role == MessageRole.user;

  factory ChatMessage.fromJson(Map<String, dynamic> json) => ChatMessage(
    id: json['id'] as String?,
    text: (json['text'] as String?) ?? '',
    role: messageRoleFromValue(json['messageRole']),
    createdAt: DateTime.tryParse('${json['createdAt']}'),
    model: json['model'] as String?,
    usage: json['usage'] is Map
        ? TokenUsage.fromJson((json['usage'] as Map).cast<String, dynamic>())
        : null,
    attachments: (json['attachments'] as List<dynamic>? ?? const [])
        .cast<Map<String, dynamic>>()
        .map(Attachment.fromJson)
        .toList(),
  );
}

/// Token counts for a model call or a running total.
///
/// Mirrors the backend's usage shape (input / output / cached / total). [turns]
/// is only present on aggregates fetched from the usage endpoints, where it is
/// the number of model calls the totals cover.
class TokenUsage {
  const TokenUsage({
    this.inputTokens = 0,
    this.outputTokens = 0,
    this.cachedInputTokens = 0,
    this.totalTokens = 0,
    this.turns = 0,
  });

  final int inputTokens;
  final int outputTokens;
  final int cachedInputTokens;
  final int totalTokens;
  final int turns;

  factory TokenUsage.fromJson(Map<String, dynamic> json) => TokenUsage(
    inputTokens: (json['inputTokens'] as num?)?.toInt() ?? 0,
    outputTokens: (json['outputTokens'] as num?)?.toInt() ?? 0,
    cachedInputTokens: (json['cachedInputTokens'] as num?)?.toInt() ?? 0,
    totalTokens: (json['totalTokens'] as num?)?.toInt() ?? 0,
    turns: (json['turns'] as num?)?.toInt() ?? 0,
  );

  /// Whether any token has been counted yet.
  bool get hasTokens =>
      inputTokens != 0 ||
      outputTokens != 0 ||
      cachedInputTokens != 0 ||
      totalTokens != 0;

  TokenUsage operator +(TokenUsage other) => TokenUsage(
    inputTokens: inputTokens + other.inputTokens,
    outputTokens: outputTokens + other.outputTokens,
    cachedInputTokens: cachedInputTokens + other.cachedInputTokens,
    totalTokens: totalTokens + other.totalTokens,
    turns: turns + other.turns,
  );
}

/// Renders a token count compactly: `999`, `1.0k`, `12.4k`, `1.2M`.
String formatTokenCount(int value) {
  final magnitude = value.abs();
  if (magnitude < 1000) return '$value';
  if (magnitude < 1000000) return '${(value / 1000).toStringAsFixed(1)}k';
  return '${(value / 1000000).toStringAsFixed(1)}M';
}

/// An input modality a model accepts.
///
/// Mirrors the backend's `ModelInputModality`, which serializes `pdf` for both
/// its `Pdf` and `file` aliases; both map to [file] here.
enum ModelInputModality { text, image, file, audio, video }

/// Maps the backend's lower-case modality string to a [ModelInputModality].
///
/// Unknown values fall back to [ModelInputModality.text] so a modality added to
/// the backend later does not crash an older client.
ModelInputModality modelInputModalityFromValue(Object? value) {
  return switch ('$value'.toLowerCase()) {
    'image' => ModelInputModality.image,
    'file' || 'pdf' => ModelInputModality.file,
    'audio' => ModelInputModality.audio,
    'video' => ModelInputModality.video,
    _ => ModelInputModality.text,
  };
}

/// The resolved input/output modalities of a model.
class ModelCapabilities {
  const ModelCapabilities({this.input = const {}, this.output = const {}});

  /// Input modalities the model accepts (never empty in practice: `text` is the
  /// backend's baseline).
  final Set<ModelInputModality> input;

  /// Output modality names (currently always `text`; kept as strings so a new
  /// output kind does not need a client release).
  final Set<String> output;

  factory ModelCapabilities.fromJson(Map<String, dynamic> json) =>
      ModelCapabilities(
        input: (json['input'] as List<dynamic>? ?? const [])
            .map(modelInputModalityFromValue)
            .toSet(),
        output: (json['output'] as List<dynamic>? ?? const [])
            .map((value) => '$value')
            .toSet(),
      );
}

/// The liveness of a model as last observed.
enum ModelHealthStatus { unknown, healthy, unhealthy }

/// Maps the backend's lower-case status string to a [ModelHealthStatus].
///
/// Unknown values fall back to [ModelHealthStatus.unknown].
ModelHealthStatus modelHealthStatusFromValue(Object? value) {
  return switch ('$value'.toLowerCase()) {
    'healthy' => ModelHealthStatus.healthy,
    'unhealthy' => ModelHealthStatus.unhealthy,
    _ => ModelHealthStatus.unknown,
  };
}

/// A point-in-time, secret-free health snapshot for one model.
///
/// [source] is advisory: `startup`, `idle`, `ondemand` or `live` (the backend
/// lower-cases its enum name). A model with recent traffic is considered live.
class ModelHealth {
  const ModelHealth({
    this.status = ModelHealthStatus.unknown,
    this.lastCheckedAt,
    this.latencyMs,
    this.lastError,
    this.lastUsedAt,
    this.source,
  });

  final ModelHealthStatus status;
  final DateTime? lastCheckedAt;
  final int? latencyMs;
  final String? lastError;
  final DateTime? lastUsedAt;
  final String? source;

  factory ModelHealth.fromJson(Map<String, dynamic> json) => ModelHealth(
    status: modelHealthStatusFromValue(json['status']),
    lastCheckedAt: DateTime.tryParse('${json['lastCheckedAt']}'),
    latencyMs: (json['latencyMs'] as num?)?.toInt(),
    lastError: json['lastError'] as String?,
    lastUsedAt: DateTime.tryParse('${json['lastUsedAt']}'),
    source: json['source'] as String?,
  );
}

/// One configured model, as returned by `GET /v1/models` (never secrets).
class ChatModel {
  const ChatModel({
    required this.slug,
    required this.name,
    this.description,
    this.provider = '',
    this.isDefault = false,
    this.capabilities = const ModelCapabilities(),
    this.health = const ModelHealth(),
  });

  /// The identifier the backend uses in requests (may contain `/`).
  final String slug;
  final String name;
  final String? description;

  /// `openrouter` or `openai-compatible`.
  final String provider;

  /// Whether this is the server's default model.
  final bool isDefault;

  final ModelCapabilities capabilities;
  final ModelHealth health;

  factory ChatModel.fromJson(Map<String, dynamic> json) {
    final slug = '${json['slug'] ?? ''}';
    return ChatModel(
      slug: slug,
      name: '${json['name'] ?? slug}',
      description: json['description'] as String?,
      provider: '${json['provider'] ?? ''}',
      isDefault: json['isDefault'] == true,
      capabilities: ModelCapabilities.fromJson(
        (json['capabilities'] as Map?)?.cast<String, dynamic>() ?? const {},
      ),
      health: ModelHealth.fromJson(
        (json['health'] as Map?)?.cast<String, dynamic>() ?? const {},
      ),
    );
  }
}
