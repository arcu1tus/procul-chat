import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:procul_chat_flutter/src/app_theme.dart';
import 'package:procul_chat_flutter/src/chat_api.dart';
import 'package:procul_chat_flutter/src/chat_controller.dart';
import 'package:procul_chat_flutter/src/chat_screen.dart';
import 'package:shadcn_flutter/shadcn_flutter.dart';
import 'package:shadcn_flutter_material/shadcn_flutter_material.dart';

import 'support/fake_conversation_store.dart';

/// A page of [count] messages with ids `<prefix><n>`, newest-first as the
/// backend returns them.
List<Map<String, dynamic>> _page(String prefix, int count, int startAt) => [
  for (var i = count; i >= 1; i--)
    {
      'id': '$prefix${startAt + i - 1}',
      'conversationId': 'c1',
      'text': '$prefix${startAt + i - 1}',
      'messageRole': i.isEven ? 1 : 2,
      'createdAt': '2026-10-11T10:00:00Z',
    },
];

const _conversation = {
  'id': 'c1',
  'title': 'Long chat',
  'createdAt': '2026-10-11T10:00:00Z',
  'updatedAt': '2026-10-11T10:00:00Z',
};

/// A client whose history page 1 is full (100 messages) and page 2 is short.
MockClient _client({
  required List<String?> cursors,
  Completer<void>? gateOlder,
}) {
  return MockClient((request) async {
    final path = request.url.path;
    if (path == '/v1/conversations' && request.method == 'GET') {
      return http.Response(
        jsonEncode({
          'conversations': [_conversation],
        }),
        200,
      );
    }
    if (path == '/v1/conversations/c1/messages') {
      final cursor = request.url.queryParameters['afterMessageId'];
      cursors.add(cursor);
      if (cursor == null) {
        return http.Response(jsonEncode({'messages': _page('m', 100, 1)}), 200);
      }
      if (gateOlder != null) await gateOlder.future;
      // Older than m1: two more messages.
      return http.Response(
        jsonEncode({
          'messages': [
            {
              'id': 'old2',
              'text': 'old2',
              'messageRole': 1,
              'createdAt': '2026-10-10T10:00:00Z',
            },
            {
              'id': 'old1',
              'text': 'old1',
              'messageRole': 2,
              'createdAt': '2026-10-09T10:00:00Z',
            },
          ],
        }),
        200,
      );
    }
    if (path.startsWith('/v1/usage/')) return http.Response('{}', 200);
    return http.Response('{}', 200);
  });
}

ChatController _chat(MockClient client) => ChatController(
  api: ChatApi(baseUrl: 'http://test', token: 'tok', client: client),
  store: FakeConversationStore('c1'),
);

void main() {
  test(
    'loadOlderMessages fetches older with afterMessageId and prepends',
    () async {
      final cursors = <String?>[];
      final chat = _chat(_client(cursors: cursors));
      await chat.init();

      expect(chat.messages, hasLength(100));
      expect(chat.hasMoreHistory, isTrue);

      await chat.loadOlderMessages();

      // The cursor is the oldest loaded id, and the results are prepended.
      expect(cursors.last, 'm1');
      expect(chat.messages, hasLength(102));
      expect(chat.messages.first.id, 'old1');
      expect(chat.messages[2].id, 'm1');
      // A short page means there is no more history.
      expect(chat.hasMoreHistory, isFalse);

      // A further call is a no-op (no more history, no extra fetch).
      final before = cursors.length;
      await chat.loadOlderMessages();
      expect(cursors.length, before);
      expect(chat.messages, hasLength(102));
    },
  );

  test('loadOlderMessages does not duplicate messages', () async {
    final cursors = <String?>[];
    final chat = _chat(_client(cursors: cursors));
    await chat.init();

    await chat.loadOlderMessages();
    final ids = chat.messages.map((m) => m.id).toList();
    expect(ids.toSet(), hasLength(ids.length));
  });

  testWidgets('a "Loading older messages…" row shows while a page loads', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1000, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    final gate = Completer<void>();
    addTearDown(() {
      if (!gate.isCompleted) gate.complete();
    });
    final client = MockClient((request) async {
      final path = request.url.path;
      if (path == '/v1/conversations' && request.method == 'GET') {
        return http.Response(
          jsonEncode({
            'conversations': [_conversation],
          }),
          200,
        );
      }
      if (path == '/v1/conversations/c1/messages') {
        final cursor = request.url.queryParameters['afterMessageId'];
        if (cursor == null) {
          // A short first page; the test asserts the paging UI directly.
          return http.Response(jsonEncode({'messages': _page('m', 3, 1)}), 200);
        }
        await gate.future;
        return http.Response(
          jsonEncode({
            'messages': [
              {
                'id': 'old1',
                'text': 'old1',
                'messageRole': 1,
                'createdAt': '2026-10-09T10:00:00Z',
              },
            ],
          }),
          200,
        );
      }
      if (path.startsWith('/v1/usage/')) return http.Response('{}', 200);
      return http.Response('{}', 200);
    });
    final chat = _chat(client);
    await chat.init();
    // Pretend the first page was full so paging is allowed.
    chat.hasMoreHistory = true;

    await tester.pumpWidget(
      MaterialShadcnApp(
        theme: proculLightTheme,
        darkTheme: proculDarkTheme,
        themeMode: ThemeMode.light,
        home: ChatScreen(chat: chat),
      ),
    );
    await tester.pumpAndSettle();

    unawaited(chat.loadOlderMessages());
    await tester.pump();

    expect(find.text('Loading older messages…'), findsOneWidget);

    gate.complete();
    await tester.pumpAndSettle();
    expect(find.text('Loading older messages…'), findsNothing);
    expect(chat.messages, hasLength(4));
    expect(tester.takeException(), isNull);
  });

  testWidgets('the jump-to-latest pill returns to the newest message', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1000, 600));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    final client = MockClient((request) async {
      final path = request.url.path;
      if (path == '/v1/conversations' && request.method == 'GET') {
        return http.Response(
          jsonEncode({
            'conversations': [_conversation],
          }),
          200,
        );
      }
      if (path == '/v1/conversations/c1/messages') {
        // A short (40 < 100) page, so paging is exhausted and scrolling does
        // not kick off another fetch.
        return http.Response(jsonEncode({'messages': _page('m', 40, 1)}), 200);
      }
      if (path.startsWith('/v1/usage/')) return http.Response('{}', 200);
      return http.Response('{}', 200);
    });
    final chat = _chat(client);
    await chat.init();
    expect(chat.messages, hasLength(40));
    expect(chat.hasMoreHistory, isFalse);

    await tester.pumpWidget(
      MaterialShadcnApp(
        theme: proculLightTheme,
        darkTheme: proculDarkTheme,
        themeMode: ThemeMode.light,
        home: ChatScreen(chat: chat),
      ),
    );
    await tester.pumpAndSettle();

    // Pinned to the bottom (the newest message) at first: no pill.
    expect(find.text('Latest'), findsNothing);

    final scrollable = find
        .descendant(
          of: find.byType(ChatScreen),
          matching: find.byType(Scrollable),
        )
        .first;
    final position = tester.state<ScrollableState>(scrollable).position;
    position.jumpTo(position.maxScrollExtent);
    await tester.pump();

    // Scrolled away → the pill appears.
    expect(find.text('Latest'), findsOneWidget);

    await tester.tap(find.text('Latest'));
    await tester.pumpAndSettle();

    // Back at offset 0 (the newest end), so the pill is gone again.
    expect(position.pixels, lessThan(140));
    expect(find.text('Latest'), findsNothing);
    expect(tester.takeException(), isNull);
  });
}
