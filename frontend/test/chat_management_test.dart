import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:procul_chat_flutter/src/chat_api.dart';
import 'package:procul_chat_flutter/src/chat_controller.dart';

import 'support/fake_conversation_store.dart';

/// SSE for a new conversation: `created` (with a placeholder title) followed by
/// a reply, then the model-generated `title` after `done`.
const _createSse =
    'data: {"value":{"conversation":{"id":"c1","title":"Placeholder",'
    '"createdAt":"2026-10-11T10:00:00Z","updatedAt":"2026-10-11T10:00:00Z"},'
    '"type":"created"}}\n\n'
    'data: {"value":{"content":"Hello","type":"token"}}\n\n'
    'data: {"value":{"type":"done"}}\n\n'
    'data: {"value":{"conversationId":"c1","title":"France capital",'
    '"type":"title"}}\n\n';

void main() {
  test('send applies the model-generated title from the title event', () async {
    final client = MockClient.streaming((request, body) async {
      return http.StreamedResponse(
        Stream.value(utf8.encode(_createSse)),
        200,
        headers: {'content-type': 'text/event-stream'},
      );
    });
    final controller = ChatController(
      api: ChatApi(baseUrl: 'http://test', token: 'test-token', client: client),
      store: FakeConversationStore(),
    );

    await controller.send('What is the capital of France?');

    expect(controller.conversations, hasLength(1));
    expect(controller.conversations.single.title, 'France capital');
    expect(controller.activeConversationId, 'c1');
    expect(controller.messages.last.text, 'Hello');
    expect(controller.isStreaming, isFalse);
  });

  test('ChatApi lists, renames, and deletes conversations', () async {
    final client = MockClient((request) async {
      final path = request.url.path;
      if (request.method == 'GET' && path == '/v1/conversations') {
        return http.Response(
          jsonEncode({
            'conversations': [
              {
                'id': 'c1',
                'title': 'First',
                'createdAt': '2026-10-11T10:00:00Z',
                'updatedAt': '2026-10-11T10:00:00Z',
              },
            ],
          }),
          200,
        );
      }
      if (request.method == 'PATCH' && path == '/v1/conversations/c1') {
        final body = jsonDecode(request.body) as Map<String, dynamic>;
        return http.Response(
          jsonEncode({
            'conversation': {
              'id': 'c1',
              'title': body['title'],
              'createdAt': '2026-10-11T10:00:00Z',
              'updatedAt': '2026-10-11T10:00:00Z',
            },
          }),
          200,
        );
      }
      if (request.method == 'DELETE' && path == '/v1/conversations/c1') {
        return http.Response('', 204);
      }
      return http.Response('not found', 404);
    });
    final api = ChatApi(
      baseUrl: 'http://test',
      token: 'test-token',
      client: client,
    );

    final listed = await api.listConversations();
    expect(listed, hasLength(1));
    expect(listed.single.title, 'First');

    final renamed = await api.renameConversation('c1', 'Renamed');
    expect(renamed.title, 'Renamed');

    await api.deleteConversation('c1');
  });

  test('rename and delete update the local conversation list', () async {
    final client = MockClient((request) async {
      if (request.method == 'GET' && request.url.path == '/v1/conversations') {
        return http.Response(
          jsonEncode({
            'conversations': [
              {
                'id': 'c1',
                'title': 'First',
                'createdAt': '2026-10-11T10:00:00Z',
                'updatedAt': '2026-10-11T10:00:00Z',
              },
            ],
          }),
          200,
        );
      }
      if (request.method == 'PATCH') {
        return http.Response(
          jsonEncode({
            'conversation': {
              'id': 'c1',
              'title': 'Renamed',
              'createdAt': '2026-10-11T10:00:00Z',
              'updatedAt': '2026-10-11T10:00:00Z',
            },
          }),
          200,
        );
      }
      if (request.method == 'DELETE') {
        return http.Response('', 204);
      }
      return http.Response('', 404);
    });
    final controller = ChatController(
      api: ChatApi(baseUrl: 'http://test', token: 'test-token', client: client),
      store: FakeConversationStore(),
    );

    await controller.init();
    expect(controller.conversations.single.title, 'First');

    await controller.renameConversation('c1', 'Renamed');
    expect(controller.conversations.single.title, 'Renamed');

    await controller.deleteConversation('c1');
    expect(controller.conversations, isEmpty);
  });
}
