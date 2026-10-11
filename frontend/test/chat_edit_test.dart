import 'dart:convert';

import 'package:flutter/gestures.dart' show PointerDeviceKind;
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

/// SSE for an edit: acknowledge → token → done (no `created`, no `title`).
const _editSse =
    'data: {"value":{"message":"received","type":"acknowledge"}}\n\n'
    'data: {"value":{"content":"new reply","type":"token"}}\n\n'
    'data: {"value":{"type":"done"}}\n\n';

const _conversation = {
  'id': 'c1',
  'title': 'Chat',
  'createdAt': '2026-10-11T10:00:00Z',
  'updatedAt': '2026-10-11T10:00:00Z',
};

/// History returned newest-first (as the backend does), so `fetchMessages`
/// reverses it into `[user, assistant]`.
const _messages = [
  {
    'id': 'm2',
    'conversationId': 'c1',
    'text': 'assistant reply',
    'messageRole': 2,
    'createdAt': '2026-10-11T10:01:00Z',
  },
  {
    'id': 'm1',
    'conversationId': 'c1',
    'text': 'original',
    'messageRole': 1,
    'createdAt': '2026-10-11T10:00:00Z',
  },
];

Widget _app(ChatScreen screen) => MaterialShadcnApp(
  theme: proculLightTheme,
  darkTheme: proculDarkTheme,
  themeMode: ThemeMode.light,
  home: screen,
);

ChatController _chat(MockClient client, {String? stored}) => ChatController(
  api: ChatApi(baseUrl: 'http://test', token: 'tok', client: client),
  store: FakeConversationStore(stored),
);

MockClient _client({
  required List<http.Request> edits,
  int? editStatus,
  void Function()? onMessageGet,
}) => MockClient((request) async {
  final path = request.url.path;
  if (path == '/v1/conversations' && request.method == 'GET') {
    return http.Response(
      jsonEncode({
        'conversations': [_conversation],
      }),
      200,
    );
  }
  if (path == '/v1/conversations/c1/messages' && request.method == 'GET') {
    onMessageGet?.call();
    return http.Response(jsonEncode({'messages': _messages}), 200);
  }
  if (path == '/v1/usage/conversations/c1') {
    return http.Response('{}', 200);
  }
  if (path == '/v1/conversations/c1/messages/m1/edit' &&
      request.method == 'POST') {
    edits.add(request);
    if (editStatus != null) {
      return http.Response('boom', editStatus);
    }
    return http.Response(
      _editSse,
      200,
      headers: {'content-type': 'text/event-stream'},
    );
  }
  return http.Response('{}', 200);
});

void main() {
  test(
    'editing truncates the tail, rewrites the message, and streams',
    () async {
      final edits = <http.Request>[];
      final chat = _chat(_client(edits: edits), stored: 'c1');
      await chat.init();
      expect(chat.messages, hasLength(2));
      expect(chat.messages.first.text, 'original');

      chat.beginEdit(chat.messages.first);
      expect(chat.isEditing, isTrue);
      expect(chat.editingMessageId, 'm1');

      await chat.editMessage('edited');

      expect(edits, hasLength(1));
      expect(jsonDecode(edits.single.body), {
        'text': 'edited',
        'attachmentIds': <dynamic>[],
      });
      // The edited user message plus exactly one fresh assistant reply.
      expect(chat.messages, hasLength(2));
      expect(chat.messages.first.text, 'edited');
      expect(chat.messages.last.text, 'new reply');
      expect(chat.isEditing, isFalse);
      expect(chat.isStreaming, isFalse);
    },
  );

  test(
    'beginEdit seeds the pending attachments and cancelEdit clears them',
    () async {
      final messages = [
        {
          'id': 'm1',
          'conversationId': 'c1',
          'text': 'with a file',
          'messageRole': 1,
          'createdAt': '2026-10-11T10:00:00Z',
          'attachments': [
            {
              'id': 'a1',
              'fileName': 'notes.txt',
              'contentType': 'text/plain',
              'sizeBytes': 5,
              'createdAt': '2026-10-11T10:00:00Z',
            },
          ],
        },
      ];
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
          return http.Response(jsonEncode({'messages': messages}), 200);
        }
        return http.Response('{}', 200);
      });
      final chat = _chat(client, stored: 'c1');
      await chat.init();

      chat.beginEdit(chat.messages.single);
      expect(chat.pendingAttachments.single.id, 'a1');

      chat.cancelEdit();
      expect(chat.isEditing, isFalse);
      expect(chat.pendingAttachments, isEmpty);
    },
  );

  test('a hard edit failure resyncs the active conversation', () async {
    var messageGets = 0;
    final chat = _chat(
      _client(edits: [], editStatus: 500, onMessageGet: () => messageGets++),
      stored: 'c1',
    );
    await chat.init();
    final before = messageGets;

    chat.beginEdit(chat.messages.first);
    await chat.editMessage('edited');

    // The resync re-fetches the history so the buffer matches the server.
    // (The resync itself resets `error`, so the follow-up GET is the signal.)
    expect(messageGets, greaterThan(before));
  });

  testWidgets('hovering a user bubble reveals Edit; submitting edits', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1000, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    final edits = <http.Request>[];
    final chat = _chat(_client(edits: edits), stored: 'c1');
    await chat.init();

    await tester.pumpWidget(_app(ChatScreen(chat: chat)));
    await tester.pumpAndSettle();

    // The Edit action is hover-revealed on user messages only.
    expect(find.byKey(const Key('edit-message')), findsNothing);

    final gesture = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await gesture.addPointer(location: Offset.zero);
    addTearDown(gesture.removePointer);
    await gesture.moveTo(tester.getCenter(find.text('original')));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('edit-message')), findsOneWidget);
    await tester.tap(find.byKey(const Key('edit-message')));
    await tester.pumpAndSettle();

    expect(find.text('Editing message'), findsOneWidget);

    await tester.enterText(find.byType(TextField), 'edited text');
    await tester.tap(find.byType(PrimaryButton));
    await tester.pumpAndSettle();

    expect(edits, hasLength(1));
    expect(jsonDecode(edits.single.body)['text'], 'edited text');
    expect(chat.isEditing, isFalse);
    expect(tester.takeException(), isNull);
  });
}
