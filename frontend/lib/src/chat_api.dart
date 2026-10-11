import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import 'models.dart';

/// Thrown when the backend returns a non-success HTTP status.
class ChatApiException implements Exception {
  ChatApiException(this.message, {this.statusCode});

  final String message;
  final int? statusCode;

  @override
  String toString() => 'ChatApiException($statusCode): $message';
}

/// Minimal client for the Procul backend's `/v1/conversations` surface.
///
/// SSE is consumed manually: the backend emits `data: {json}` lines (with no
/// `event:` name) followed by a blank line, and carries the event kind inside
/// the JSON as `value.type`.
class ChatApi {
  ChatApi({required this.baseUrl, http.Client? client})
    : _client = client ?? http.Client();

  final String baseUrl;
  final http.Client _client;

  Uri _uri(String path, [Map<String, String>? query]) =>
      Uri.parse('$baseUrl$path').replace(queryParameters: query);

  /// `GET /v1/conversations/{id}/messages`
  ///
  /// The backend returns messages newest-first (keyset paginated). This returns
  /// them oldest-first so they can be appended to the UI buffer directly.
  Future<List<ChatMessage>> fetchMessages(
    String conversationId, {
    int limit = 100,
  }) async {
    final response = await _client.get(
      _uri('/v1/conversations/$conversationId/messages', {'limit': '$limit'}),
    );

    if (response.statusCode != 200) {
      throw ChatApiException(response.body, statusCode: response.statusCode);
    }

    final body = jsonDecode(response.body) as Map<String, dynamic>;
    final messages = (body['messages'] as List<dynamic>? ?? const [])
        .cast<Map<String, dynamic>>()
        .map(ChatMessage.fromJson)
        .toList();

    return messages.reversed.toList(growable: false);
  }

  /// `POST /v1/conversations` — creates a conversation and streams the reply.
  Stream<ChatStreamEvent> createConversation(String initialMessage) => _stream(
    _postSse('/v1/conversations/', {'initialMessage': initialMessage}),
  );

  /// `POST /v1/conversations/{id}/messages` — streams the assistant's reply.
  Stream<ChatStreamEvent> sendMessage(String conversationId, String text) =>
      _stream(
        _postSse('/v1/conversations/$conversationId/messages', {'text': text}),
      );

  Future<http.StreamedResponse> _postSse(
    String path,
    Map<String, Object?> body,
  ) {
    final request = http.Request('POST', _uri(path))
      ..headers.addAll(_sseHeaders)
      ..body = jsonEncode(body);
    return _client.send(request);
  }

  void close() => _client.close();

  static const _sseHeaders = {
    'Content-Type': 'application/json',
    'Accept': 'text/event-stream',
  };

  Stream<ChatStreamEvent> _stream(
    Future<http.StreamedResponse> request,
  ) async* {
    final response = await request;

    if (response.statusCode != 200) {
      final body = await response.stream.bytesToString();
      throw ChatApiException(body, statusCode: response.statusCode);
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
      'done' => const DoneEvent(),
      _ => null,
    };
  }
}
