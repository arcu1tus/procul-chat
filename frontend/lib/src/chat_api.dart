import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:http/http.dart' as http;
import 'package:http_parser/http_parser.dart' show MediaType;

import 'attachments.dart';
import 'chat_stream_event.dart';
import 'mcp_status.dart';
import 'models.dart';
import 'usage.dart';

/// Thrown when the backend returns a non-success HTTP status.
class ChatApiException implements Exception {
  ChatApiException(this.message, {this.statusCode});

  final String message;
  final int? statusCode;

  @override
  String toString() => 'ChatApiException($statusCode): $message';
}

/// Thrown when the backend rejects the session token (`401`). The caller should
/// sign in again.
class UnauthorizedException extends ChatApiException {
  UnauthorizedException([
    super.message =
        'Your session has expired or is no longer valid. Please sign in again.',
  ]) : super(statusCode: 401);
}

/// Minimal client for the Procul backend's `/v1/conversations` surface.
///
/// Every request carries the session token as `Authorization: Bearer …`. A
/// `401` raises [UnauthorizedException] and invokes [onUnauthorized] once, so
/// the app can bounce back to the Connect screen.
///
/// SSE is consumed manually: the backend emits `data: {json}` lines (with no
/// `event:` name) followed by a blank line, and carries the event kind inside
/// the JSON as `value.type`.
class ChatApi {
  ChatApi({
    required this.baseUrl,
    required this.token,
    http.Client? client,
    this.onUnauthorized,
  }) : _client = client ?? http.Client();

  final String baseUrl;
  final String token;
  final http.Client _client;

  /// Called at most once, on the first `401`, so the app can log out.
  final void Function()? onUnauthorized;

  bool _unauthorizedNotified = false;

  Map<String, String> get _authHeaders => {'Authorization': 'Bearer $token'};

  Uri _uri(String path, [Map<String, String>? query]) =>
      Uri.parse('$baseUrl$path').replace(queryParameters: query);

  /// `GET /v1/conversations`
  ///
  /// Returns every conversation, most recently active first (as ordered by the
  /// backend).
  Future<List<Conversation>> listConversations() async {
    final response = await _client.get(
      _uri('/v1/conversations'),
      headers: _authHeaders,
    );

    if (response.statusCode != 200) {
      _throwHttpError(response.statusCode, response.body);
    }

    final body = jsonDecode(response.body) as Map<String, dynamic>;
    return (body['conversations'] as List<dynamic>? ?? const [])
        .cast<Map<String, dynamic>>()
        .map(Conversation.fromJson)
        .toList(growable: false);
  }

  /// `PATCH /v1/conversations/{id}` — renames a conversation, returning the
  /// updated record.
  ///
  /// [expectedRevision] is the revision the client last saw; a stale value makes
  /// the backend answer `409` so two devices cannot silently clobber each other.
  Future<Conversation> renameConversation(
    String id,
    String title, {
    int? expectedRevision,
  }) async {
    final response = await _client.patch(
      _uri('/v1/conversations/$id'),
      headers: {..._authHeaders, 'Content-Type': 'application/json'},
      body: jsonEncode({'title': title, 'expectedRevision': ?expectedRevision}),
    );

    if (response.statusCode != 200) {
      _throwHttpError(response.statusCode, response.body);
    }

    final body = jsonDecode(response.body) as Map<String, dynamic>;
    return Conversation.fromJson(
      (body['conversation'] as Map).cast<String, dynamic>(),
    );
  }

  /// `DELETE /v1/conversations/{id}` — removes a conversation and its messages.
  ///
  /// A 404 is treated as success: the goal state (gone) is already achieved.
  Future<void> deleteConversation(String id) async {
    final response = await _client.delete(
      _uri('/v1/conversations/$id'),
      headers: _authHeaders,
    );

    if (response.statusCode != 204 && response.statusCode != 404) {
      _throwHttpError(response.statusCode, response.body);
    }
  }

  /// `POST /v1/attachments` — uploads a file as multipart/form-data and returns
  /// its metadata. The bytes are sent once; renders later fetch them by id.
  ///
  /// [model] names the model the file is meant for; the backend rejects a type
  /// that model cannot read (the same rule the send gate enforces). Omit it to
  /// let the backend use its default model.
  Future<Attachment> uploadAttachment({
    required Uint8List bytes,
    required String fileName,
    required String contentType,
    String? model,
  }) async {
    final request =
        http.MultipartRequest(
            'POST',
            _uri('/v1/attachments', model == null ? null : {'model': model}),
          )
          ..headers.addAll(_authHeaders)
          ..files.add(
            http.MultipartFile.fromBytes(
              'file',
              bytes,
              filename: fileName,
              contentType: MediaType.parse(contentType),
            ),
          );

    final response = await http.Response.fromStream(
      await _client.send(request),
    );

    if (response.statusCode != 201) {
      _throwHttpError(response.statusCode, response.body);
    }

    return Attachment.fromJson(
      jsonDecode(response.body) as Map<String, dynamic>,
    );
  }

  /// `GET /v1/attachments/{id}` — the raw bytes, authenticated.
  ///
  /// Always fetch through this client (never a plain `<img>` URL), because the
  /// request needs the bearer header.
  Future<Uint8List> fetchAttachmentBytes(String id) async {
    final response = await _client.get(
      _uri('/v1/attachments/$id'),
      headers: _authHeaders,
    );

    if (response.statusCode != 200) {
      _throwHttpError(response.statusCode, response.body);
    }

    return response.bodyBytes;
  }

  /// `DELETE /v1/attachments/{id}` — removes an uploaded file. A 404 is treated
  /// as success (the goal state is already achieved).
  Future<void> deleteAttachment(String id) async {
    final response = await _client.delete(
      _uri('/v1/attachments/$id'),
      headers: _authHeaders,
    );

    if (response.statusCode != 204 && response.statusCode != 404) {
      _throwHttpError(response.statusCode, response.body);
    }
  }

  /// `GET /v1/conversations/{id}/messages`
  ///
  /// The backend returns messages newest-first (keyset paginated). This returns
  /// them oldest-first so they can be appended to the UI buffer directly.
  ///
  /// [afterMessageId] is the backend's keyset cursor: it returns the page of
  /// messages *older* than that id (`CreatedAt < cursor`), so passing the oldest
  /// loaded id fetches the previous page (infinite scroll up).
  Future<List<ChatMessage>> fetchMessages(
    String conversationId, {
    int limit = 100,
    String? afterMessageId,
  }) async {
    final response = await _client.get(
      _uri('/v1/conversations/$conversationId/messages', {
        'limit': '$limit',
        'afterMessageId': ?afterMessageId,
      }),
      headers: _authHeaders,
    );

    if (response.statusCode != 200) {
      _throwHttpError(response.statusCode, response.body);
    }

    final body = jsonDecode(response.body) as Map<String, dynamic>;
    final messages = (body['messages'] as List<dynamic>? ?? const [])
        .cast<Map<String, dynamic>>()
        .map(ChatMessage.fromJson)
        .toList();

    return messages.reversed.toList(growable: false);
  }

  /// `GET /v1/mcp/servers` — live, secret-free status of the configured MCP servers.
  ///
  /// Goes through this client so it inherits the bearer header and the `401 → logout` path.
  Future<List<McpServerStatus>> fetchMcpServers() async {
    final response = await _client.get(
      _uri('/v1/mcp/servers'),
      headers: _authHeaders,
    );

    if (response.statusCode != 200) {
      _throwHttpError(response.statusCode, response.body);
    }

    final body = jsonDecode(response.body) as Map<String, dynamic>;
    return (body['servers'] as List<dynamic>? ?? const [])
        .cast<Map<String, dynamic>>()
        .map(McpServerStatus.fromJson)
        .toList(growable: false);
  }

  /// `GET /v1/usage/conversations/{id}` — all-time token totals for one conversation.
  ///
  /// Seeds the in-chat counter when a conversation is opened; the client then adds
  /// each turn's `usage` event to the running total.
  Future<TokenUsage> fetchConversationUsage(String conversationId) async {
    final response = await _client.get(
      _uri('/v1/usage/conversations/$conversationId'),
      headers: _authHeaders,
    );

    if (response.statusCode != 200) {
      _throwHttpError(response.statusCode, response.body);
    }

    return TokenUsage.fromJson(
      jsonDecode(response.body) as Map<String, dynamic>,
    );
  }

  /// `GET /v1/usage?days=n` — lifetime totals plus a per-day / per-model breakdown.
  Future<UsageSummary> fetchUsage({int days = 30}) async {
    final response = await _client.get(
      _uri('/v1/usage', {'days': '$days'}),
      headers: _authHeaders,
    );

    if (response.statusCode != 200) {
      _throwHttpError(response.statusCode, response.body);
    }

    return UsageSummary.fromJson(
      jsonDecode(response.body) as Map<String, dynamic>,
    );
  }

  /// `GET /v1/models` — the configured models with capabilities and live health.
  ///
  /// Never includes secrets. The default model is the entry flagged `isDefault`.
  Future<List<ChatModel>> fetchModels() async {
    final response = await _client.get(
      _uri('/v1/models'),
      headers: _authHeaders,
    );

    if (response.statusCode != 200) {
      _throwHttpError(response.statusCode, response.body);
    }

    final body = jsonDecode(response.body) as Map<String, dynamic>;
    return (body['models'] as List<dynamic>? ?? const [])
        .cast<Map<String, dynamic>>()
        .map(ChatModel.fromJson)
        .toList(growable: false);
  }

  /// `POST /v1/models/check` — re-probes every health-checked model.
  Future<void> checkModels() async {
    final response = await _client.post(
      _uri('/v1/models/check'),
      headers: _authHeaders,
    );

    if (response.statusCode != 200) {
      _throwHttpError(response.statusCode, response.body);
    }
  }

  /// `POST /v1/models/{slug}/check` — re-probes one model.
  ///
  /// [slug] may contain `/` (e.g. `vendor/model`); the backend's catch-all route
  /// handles the extra segments.
  Future<void> checkModel(String slug) async {
    final response = await _client.post(
      _uri('/v1/models/$slug/check'),
      headers: _authHeaders,
    );

    if (response.statusCode != 200) {
      _throwHttpError(response.statusCode, response.body);
    }
  }

  /// `PUT /v1/conversations/{id}/model` — sets the conversation's model.
  ///
  /// [expectedRevision] follows the same rule as [renameConversation].
  Future<Conversation> setConversationModel(
    String id,
    String slug, {
    int? expectedRevision,
  }) async {
    final response = await _client.put(
      _uri('/v1/conversations/$id/model'),
      headers: {..._authHeaders, 'Content-Type': 'application/json'},
      body: jsonEncode({'model': slug, 'expectedRevision': ?expectedRevision}),
    );

    if (response.statusCode != 200) {
      _throwHttpError(response.statusCode, response.body);
    }

    final body = jsonDecode(response.body) as Map<String, dynamic>;
    return Conversation.fromJson(
      (body['conversation'] as Map).cast<String, dynamic>(),
    );
  }

  /// `POST /v1/conversations` — creates a conversation and streams the reply.
  ///
  /// [model] selects the model for the new conversation; omit it to let the
  /// backend use its default. [attachmentIds] references previously uploaded
  /// files to attach to the first user message.
  Stream<ChatStreamEvent> createConversation(
    String initialMessage, {
    String? model,
    List<String>? attachmentIds,
  }) => _stream(
    _postSse('/v1/conversations/', {
      'initialMessage': initialMessage,
      'model': ?model,
      if (attachmentIds != null && attachmentIds.isNotEmpty)
        'attachmentIds': attachmentIds,
    }),
  );

  /// `POST /v1/conversations/{id}/messages` — streams the assistant's reply.
  ///
  /// [expectedRevision] is the conversation's last-seen revision; a stale value
  /// makes the backend answer `409` before the stream starts.
  Stream<ChatStreamEvent> sendMessage(
    String conversationId,
    String text, {
    List<String>? attachmentIds,
    int? expectedRevision,
  }) => _stream(
    _postSse('/v1/conversations/$conversationId/messages', {
      'text': text,
      if (attachmentIds != null && attachmentIds.isNotEmpty)
        'attachmentIds': attachmentIds,
      'expectedRevision': ?expectedRevision,
    }),
  );

  /// `POST /v1/conversations/{id}/messages/{messageId}/edit` — rewrites a user message and
  /// streams the model's new reply. Editing is destructive: the backend discards every later
  /// message (and their attachments) first.
  ///
  /// [attachmentIds] follows the backend rule: null keeps the message's current attachments,
  /// an empty list removes them all, and a list replaces them with exactly those.
  Stream<ChatStreamEvent> editMessage(
    String conversationId,
    String messageId,
    String text, {
    List<String>? attachmentIds,
    int? expectedRevision,
  }) => _stream(
    _postSse('/v1/conversations/$conversationId/messages/$messageId/edit', {
      'text': text,
      'attachmentIds': ?attachmentIds,
      'expectedRevision': ?expectedRevision,
    }),
  );

  Future<http.StreamedResponse> _postSse(
    String path,
    Map<String, Object?> body,
  ) {
    final request = http.Request('POST', _uri(path))
      ..headers.addAll({..._authHeaders, ..._sseHeaders})
      ..body = jsonEncode(body);
    return _client.send(request);
  }

  void close() => _client.close();

  static const _sseHeaders = {
    'Content-Type': 'application/json',
    'Accept': 'text/event-stream',
  };

  /// Raises the appropriate exception for a non-success response, notifying
  /// [onUnauthorized] once on the first `401`.
  Never _throwHttpError(int statusCode, String body) {
    if (statusCode == 401) {
      if (!_unauthorizedNotified) {
        _unauthorizedNotified = true;
        onUnauthorized?.call();
      }
      throw UnauthorizedException();
    }
    throw ChatApiException(body, statusCode: statusCode);
  }

  Stream<ChatStreamEvent> _stream(
    Future<http.StreamedResponse> request,
  ) async* {
    final response = await request;

    if (response.statusCode != 200) {
      final body = await response.stream.bytesToString();
      _throwHttpError(response.statusCode, body);
    }

    final lines = response.stream
        .transform(utf8.decoder)
        .transform(const LineSplitter());

    // Buffer `data:` lines until the blank line that terminates an SSE event.
    final data = StringBuffer();

    await for (final line in lines) {
      if (line.isEmpty) {
        final raw = data.toString();
        data.clear();
        if (raw.isEmpty) continue;
        final event = _decodeEvent(raw);
        if (event != null) yield event;
        continue;
      }

      // Ignore other SSE fields (`event:`, `id:`, `retry:`, comments).
      if (line.startsWith('data:')) {
        if (data.isNotEmpty) data.write('\n');
        data.write(line.substring(5).trimLeft());
      }
    }

    // Flush a final event if the stream ended without a trailing blank line.
    final tail = data.toString();
    if (tail.isNotEmpty) {
      final event = _decodeEvent(tail);
      if (event != null) yield event;
    }
  }

  static ChatStreamEvent? _decodeEvent(String raw) {
    final Object? decoded;
    try {
      decoded = jsonDecode(raw);
    } on FormatException {
      return null;
    }

    if (decoded is! Map) return null;
    final value = decoded['value'];
    if (value is! Map) return null;

    return switch (value['type']) {
      'created' => CreatedEvent(
        Conversation.fromJson(
          (value['conversation'] as Map).cast<String, dynamic>(),
        ),
      ),
      'acknowledge' => const AcknowledgeEvent(),
      'token' => TokenEvent('${value['content'] ?? ''}'),
      'image' => ImageEvent(
        Attachment(
          id: '${value['attachmentId']}',
          fileName: value['fileName'] as String? ?? 'image',
          contentType: value['contentType'] as String? ?? 'image/png',
          sizeBytes: 0,
        ),
      ),
      'title' => TitleEvent(
        conversationId: '${value['conversationId'] ?? ''}',
        title: '${value['title'] ?? ''}',
      ),
      'toolCall' => ToolCallEvent(
        callId: '${value['callId'] ?? ''}',
        name: '${value['name'] ?? ''}',
        arguments: value['arguments'] as String?,
      ),
      'toolResult' => ToolResultEvent(
        callId: '${value['callId'] ?? ''}',
        result: value['result'] as String?,
        error: value['error'] as String?,
      ),
      'error' => ErrorEvent('${value['error'] ?? 'unknown error'}'),
      'usage' => UsageEvent(
        TokenUsage(
          inputTokens: (value['inputTokens'] as num?)?.toInt() ?? 0,
          outputTokens: (value['outputTokens'] as num?)?.toInt() ?? 0,
          cachedInputTokens: (value['cachedInputTokens'] as num?)?.toInt() ?? 0,
          totalTokens: (value['totalTokens'] as num?)?.toInt() ?? 0,
        ),
        model: value['model'] as String?,
      ),
      'done' => DoneEvent(revision: (value['revision'] as num?)?.toInt()),
      _ => null,
    };
  }
}
