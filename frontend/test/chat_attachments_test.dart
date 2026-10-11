import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:procul_chat_flutter/src/app_theme.dart';
import 'package:procul_chat_flutter/src/attachments.dart';
import 'package:procul_chat_flutter/src/chat_api.dart';
import 'package:procul_chat_flutter/src/chat_controller.dart';
import 'package:procul_chat_flutter/src/chat_screen.dart';
import 'package:shadcn_flutter/shadcn_flutter.dart';
import 'package:shadcn_flutter_material/shadcn_flutter_material.dart';

import 'support/fake_attachment_picker.dart';
import 'support/fake_conversation_store.dart';

/// A valid 1x1 PNG, so `Image.memory` can decode the fake bytes.
final _pngBytes = base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAAC0lEQVR42mNkYAAAAAYA'
  'AjCB0C8AAAAASUVORK5CYII=',
);

final _textBytes = Uint8List.fromList(utf8.encode('hello'));

const _sse =
    'data: {"value":{"conversation":{"id":"c1","title":"t",'
    '"createdAt":"2026-10-11T10:00:00Z","updatedAt":"2026-10-11T10:00:00Z"},'
    '"type":"created"}}\n\n'
    'data: {"value":{"content":"ok","type":"token"}}\n\n'
    'data: {"value":{"type":"done"}}\n\n';

Widget _app(ChatScreen screen) => MaterialShadcnApp(
  theme: proculLightTheme,
  darkTheme: proculDarkTheme,
  themeMode: ThemeMode.light,
  home: screen,
);

/// A backend that serves one conversation whose single user message carries the
/// given [attachment].
MockClient _historyClient(Map<String, dynamic> attachment, Uint8List bytes) =>
    MockClient((request) async {
      final path = request.url.path;
      if (path == '/v1/conversations' && request.method == 'GET') {
        return http.Response(
          jsonEncode({
            'conversations': [
              {
                'id': 'c1',
                'title': 'Files',
                'createdAt': '2026-10-11T10:00:00Z',
                'updatedAt': '2026-10-11T10:00:00Z',
              },
            ],
          }),
          200,
        );
      }
      if (path == '/v1/conversations/c1/messages' && request.method == 'GET') {
        return http.Response(
          jsonEncode({
            'messages': [
              {
                'id': 'm1',
                'conversationId': 'c1',
                'text': 'look at this',
                'messageRole': 1,
                'createdAt': '2026-10-11T10:00:00Z',
                'attachments': [attachment],
              },
            ],
          }),
          200,
        );
      }
      if (path == '/v1/usage/conversations/c1') {
        return http.Response('{}', 200);
      }
      if (path == '/v1/attachments/${attachment['id']}') {
        return http.Response.bytes(bytes, 200);
      }
      return http.Response('{}', 200);
    });

ChatController _chat(MockClient client, {String? stored}) => ChatController(
  api: ChatApi(baseUrl: 'http://test', token: 'tok', client: client),
  store: FakeConversationStore(stored),
);

void main() {
  test('uploading queues an attachment and send forwards its id', () async {
    final creates = <http.Request>[];
    final client = MockClient((request) async {
      final path = request.url.path;
      if (path == '/v1/attachments' && request.method == 'POST') {
        return http.Response(
          jsonEncode({
            'id': 'a1',
            'fileName': 'notes.txt',
            'contentType': 'text/plain',
            'sizeBytes': 5,
            'createdAt': '2026-10-11T10:00:00Z',
          }),
          201,
        );
      }
      if (path == '/v1/conversations/' && request.method == 'POST') {
        creates.add(request);
        return http.Response(
          _sse,
          200,
          headers: {'content-type': 'text/event-stream'},
        );
      }
      return http.Response('{}', 200);
    });
    final chat = _chat(client);

    final uploaded = await chat.uploadAttachment(
      PickedAttachment(
        bytes: _textBytes,
        fileName: 'notes.txt',
        contentType: 'text/plain',
      ),
    );
    expect(uploaded, isTrue);
    expect(chat.pendingAttachments, hasLength(1));

    await chat.send('have a look');

    expect(creates, hasLength(1));
    expect(jsonDecode(creates.single.body), {
      'initialMessage': 'have a look',
      'attachmentIds': ['a1'],
    });
    expect(chat.pendingAttachments, isEmpty);

    final user = chat.messages.firstWhere((message) => message.isUser);
    expect(user.attachments.single.id, 'a1');
    expect(user.attachments.single.fileName, 'notes.txt');
  });

  test('uploadAttachment tells the backend which model it is for', () async {
    http.Request? upload;
    final client = MockClient((request) async {
      if (request.url.path == '/v1/attachments' && request.method == 'POST') {
        upload = request;
        return http.Response(
          jsonEncode({
            'id': 'a1',
            'fileName': 'notes.txt',
            'contentType': 'text/plain',
            'sizeBytes': 5,
            'createdAt': '2026-10-11T10:00:00Z',
          }),
          201,
        );
      }
      return http.Response('{}', 200);
    });
    final chat = _chat(client)..setDefaultModel('openai/gpt-4o-mini');

    await chat.uploadAttachment(
      PickedAttachment(
        bytes: _textBytes,
        fileName: 'notes.txt',
        contentType: 'text/plain',
      ),
    );

    expect(upload, isNotNull);
    expect(upload!.url.queryParameters['model'], 'openai/gpt-4o-mini');
  });

  test('removePendingAttachment drops a queued file', () async {
    final client = MockClient(
      (request) async => http.Response(
        jsonEncode({
          'id': 'a1',
          'fileName': 'notes.txt',
          'contentType': 'text/plain',
          'sizeBytes': 5,
          'createdAt': '2026-10-11T10:00:00Z',
        }),
        201,
      ),
    );
    final chat = _chat(client);

    await chat.uploadAttachment(
      PickedAttachment(
        bytes: _textBytes,
        fileName: 'notes.txt',
        contentType: 'text/plain',
      ),
    );
    expect(chat.pendingAttachments, hasLength(1));

    chat.removePendingAttachment('a1');
    expect(chat.pendingAttachments, isEmpty);
  });

  testWidgets('a persisted image renders through Image.memory', (tester) async {
    await tester.binding.setSurfaceSize(const Size(1000, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    final chat = _chat(
      _historyClient({
        'id': 'a1',
        'fileName': 'photo.png',
        'contentType': 'image/png',
        'sizeBytes': _pngBytes.length,
        'createdAt': '2026-10-11T10:00:00Z',
      }, _pngBytes),
      stored: 'c1',
    );
    await chat.init();
    expect(chat.messages.single.attachments.single.isImage, isTrue);

    await tester.pumpWidget(_app(ChatScreen(chat: chat)));
    await tester.pumpAndSettle();

    expect(
      find.byWidgetPredicate(
        (widget) => widget is Image && widget.image is MemoryImage,
      ),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('tapping a persisted file chip saves it through the picker', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1000, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    final picker = FakeAttachmentPicker();
    final chat = _chat(
      _historyClient({
        'id': 'a1',
        'fileName': 'notes.txt',
        'contentType': 'text/plain',
        'sizeBytes': _textBytes.length,
        'createdAt': '2026-10-11T10:00:00Z',
      }, _textBytes),
      stored: 'c1',
    );
    await chat.init();

    await tester.pumpWidget(_app(ChatScreen(chat: chat, picker: picker)));
    await tester.pumpAndSettle();

    expect(find.text('notes.txt'), findsOneWidget);

    await tester.tap(find.text('notes.txt'));
    await tester.pumpAndSettle();

    expect(picker.saved, hasLength(1));
    expect(picker.saved.single.$1, 'notes.txt');
    expect(picker.saved.single.$2, _textBytes);
    expect(tester.takeException(), isNull);
  });
}
