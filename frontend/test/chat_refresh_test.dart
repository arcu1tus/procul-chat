import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:procul_chat_flutter/src/attachments.dart';
import 'package:procul_chat_flutter/src/chat_api.dart';
import 'package:procul_chat_flutter/src/chat_controller.dart';

import 'support/fake_conversation_store.dart';

Map<String, Object> _message(String id, String text, int role) => {
  'id': id,
  'text': text,
  'messageRole': role,
};

final _initial = [_message('u1', 'Hi', 1), _message('a1', 'Hello', 2)];
final _turn = [_message('u2', 'Hi', 1), _message('a2', 'Hello', 2)];

http.Response _history(List<Map<String, Object>> messages) =>
    http.Response(jsonEncode({'messages': messages.reversed.toList()}), 200);

ChatController _chat({
  required Future<http.Response> Function(http.Request) history,
  void Function()? onSend,
}) => ChatController(
  api: ChatApi(
    baseUrl: 'http://test',
    token: 'tok',
    client: MockClient((request) async {
      if (request.url.path == '/v1/conversations') {
        return http.Response(
          jsonEncode({
            'conversations': [
              {'id': 'c1', 'title': 'Chat'},
            ],
          }),
          200,
        );
      }
      if (request.method == 'POST') {
        onSend?.call();
        return http.Response(
          'data: {"value":{"content":"Hello","type":"token"}}\n\n'
          'data: {"value":{"type":"done"}}\n\n',
          200,
          headers: {'content-type': 'text/event-stream'},
        );
      }
      if (request.url.path.endsWith('/messages')) return history(request);
      return http.Response('{}', 200);
    }),
  ),
  store: FakeConversationStore('c1'),
);

void main() {
  test(
    'sync gives streamed bubbles IDs without duplicating repeated text',
    () async {
      var remote = [..._initial];
      final chat = _chat(
        history: (_) async => _history(remote),
        onSend: () => remote.addAll(_turn),
      );
      addTearDown(chat.dispose);
      await chat.init();
      await chat.send('Hi');
      final user = chat.messages[2];
      final assistant = chat.messages[3];
      expect(user.id, isNull);
      expect(assistant.id, isNull);

      // Repeated identical text from another device is a distinct, later turn.
      remote.addAll([_message('u3', 'Hi', 1), _message('a3', 'Hello', 2)]);
      await chat.syncActiveConversation();
      await chat.syncActiveConversation();
      expect(chat.messages.map((m) => m.id), [
        'u1',
        'a1',
        'u2',
        'a2',
        'u3',
        'a3',
      ]);
      expect(chat.messages[2], same(user));
      expect(chat.messages[3], same(assistant));

      await chat.reloadActiveConversation();
      await chat.syncActiveConversation();
      expect(chat.messages, hasLength(6));
    },
  );

  test(
    'partial history does not duplicate a local turn before it is persisted',
    () async {
      var remote = [..._initial];
      final chat = _chat(history: (_) async => _history(remote));
      addTearDown(chat.dispose);
      await chat.init();
      await chat.send('Hi');

      remote.add(_turn.first);
      await chat.syncActiveConversation();
      expect(chat.messages, hasLength(4));
      expect(chat.messages.last.id, isNull);

      remote.add(_turn.last);
      var notifications = 0;
      chat.addListener(() => notifications++);
      await chat.syncActiveConversation();
      expect(chat.messages.map((m) => m.id), ['u1', 'a1', 'u2', 'a2']);
      expect(notifications, 1);
      await chat.syncActiveConversation();
      expect(notifications, 1);
    },
  );

  test('sync reconciles a new conversation with no persisted anchor', () async {
    var remote = <Map<String, Object>>[];
    final chat = _chat(history: (_) async => _history(remote));
    addTearDown(chat.dispose);
    await chat.init();
    await chat.send('Hi');
    remote = [..._turn];
    await chat.syncActiveConversation();
    expect(chat.messages.map((m) => m.id), ['u2', 'a2']);
  });

  test(
    'sync matches attachment IDs without relying on attachment order',
    () async {
      var remote = [..._initial];
      final chat = _chat(history: (_) async => _history(remote));
      addTearDown(chat.dispose);
      await chat.init();
      chat.pendingAttachments.addAll([
        for (final id in ['file1', 'file2'])
          Attachment(
            id: id,
            fileName: '$id.txt',
            contentType: 'text/plain',
            sizeBytes: 10,
          ),
      ]);
      await chat.send('Hi');
      remote = [
        ..._initial,
        {
          ..._turn.first,
          'attachments': [
            {'id': 'other-file'},
          ],
        },
        _turn.last,
      ];
      await chat.syncActiveConversation();
      expect(chat.messages, hasLength(4));
      expect(chat.messages[2].id, isNull);

      remote[2] = {
        ..._turn.first,
        'attachments': [
          {'id': 'file2'},
          {'id': 'file1'},
        ],
      };
      await chat.syncActiveConversation();
      expect(chat.messages.map((m) => m.id), ['u1', 'a1', 'u2', 'a2']);
    },
  );

  test(
    'sync reconciles the assistant after editing a persisted user message',
    () async {
      var remote = [..._initial];
      final chat = _chat(history: (_) async => _history(remote));
      addTearDown(chat.dispose);
      await chat.init();
      chat.beginEdit(chat.messages.first);
      await chat.editMessage('Edited');
      remote = [_message('u1', 'Edited', 1), _message('a2', 'Hello', 2)];
      await chat.syncActiveConversation();
      expect(chat.messages.map((m) => m.id), ['u1', 'a2']);
      expect(chat.messages.first.text, 'Edited');
    },
  );

  test(
    'a page started before reload cannot append stale older messages',
    () async {
      final older = Completer<http.Response>();
      final chat = _chat(
        history: (request) async =>
            request.url.queryParameters.containsKey('afterMessageId')
            ? older.future
            : _history(_initial),
      );
      addTearDown(chat.dispose);
      await chat.init();
      chat.hasMoreHistory = true;
      final paging = chat.loadOlderMessages();
      expect(chat.isLoadingOlder, isTrue);

      await chat.reloadActiveConversation();
      older.complete(_history([_message('old', 'Old', 1)]));
      await paging;
      expect(chat.messages.map((m) => m.id), ['u1', 'a1']);
      expect(chat.isLoadingOlder, isFalse);
      expect(chat.hasMoreHistory, isFalse);
    },
  );

  test(
    'a sync started before reload cannot reintroduce stale messages',
    () async {
      final stale = Completer<http.Response>();
      var calls = 0;
      final chat = _chat(
        history: (_) async => ++calls == 2 ? stale.future : _history(_initial),
      );
      addTearDown(chat.dispose);
      await chat.init();
      final syncing = chat.syncActiveConversation();
      await chat.reloadActiveConversation();
      stale.complete(_history([..._initial, _message('stale', 'Removed', 1)]));
      await syncing;
      expect(chat.messages.map((m) => m.id), ['u1', 'a1']);
    },
  );

  test(
    'a sync started before sending cannot duplicate the completed turn',
    () async {
      final stale = Completer<http.Response>();
      var calls = 0;
      final chat = _chat(
        history: (_) async => ++calls == 2 ? stale.future : _history(_initial),
      );
      addTearDown(chat.dispose);
      await chat.init();
      final syncing = chat.syncActiveConversation();
      await chat.send('Hi');
      stale.complete(_history([..._initial, ..._turn]));
      await syncing;
      expect(chat.messages, hasLength(4));
      expect(chat.messages.last.id, isNull);
    },
  );

  test(
    'overlapping reloads keep the newest response and its loading state',
    () async {
      final first = Completer<http.Response>();
      final second = Completer<http.Response>();
      var calls = 0;
      final chat = _chat(
        history: (_) async => switch (++calls) {
          2 => first.future,
          3 => second.future,
          _ => _history(_initial),
        },
      );
      addTearDown(chat.dispose);
      await chat.init();
      final reload1 = chat.reloadActiveConversation();
      final reload2 = chat.reloadActiveConversation();
      first.complete(_history([_message('stale', 'Removed', 1)]));
      await reload1;
      expect(chat.isLoadingMessages, isTrue);
      second.complete(_history([..._initial, ..._turn]));
      await reload2;
      expect(chat.isLoadingMessages, isFalse);
      expect(chat.messages.map((m) => m.id), ['u1', 'a1', 'u2', 'a2']);
    },
  );

  test('starting a new chat discards an outstanding history load', () async {
    final stale = Completer<http.Response>();
    var calls = 0;
    final chat = _chat(
      history: (_) async => ++calls == 2 ? stale.future : _history(_initial),
    );
    addTearDown(chat.dispose);
    await chat.init();
    final reloading = chat.reloadActiveConversation();
    await chat.newChat();
    stale.complete(_history(_initial));
    await reloading;
    expect(chat.activeConversationId, isNull);
    expect(chat.messages, isEmpty);
    expect(chat.isLoadingMessages, isFalse);
  });
}
