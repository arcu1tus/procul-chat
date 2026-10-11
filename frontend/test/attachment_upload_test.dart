import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:procul_chat_flutter/src/app_theme.dart';
import 'package:procul_chat_flutter/src/attachments.dart';
import 'package:procul_chat_flutter/src/chat_api.dart';
import 'package:procul_chat_flutter/src/chat_controller.dart';
import 'package:procul_chat_flutter/src/chat_screen.dart';
import 'package:procul_chat_flutter/src/model_catalog_controller.dart';
import 'package:procul_chat_flutter/src/models.dart';
import 'package:shadcn_flutter/shadcn_flutter.dart';
import 'package:shadcn_flutter_material/shadcn_flutter_material.dart';

import 'support/fake_attachment_picker.dart';
import 'support/fake_conversation_store.dart';

/// A valid 1x1 PNG, so `Image.memory` can decode the fake bytes.
final _pngBytes = base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAAC0lEQVR42mNkYAAAAAYA'
  'AjCB0C8AAAAASUVORK5CYII=',
);

Widget _app(ChatScreen screen) => MaterialShadcnApp(
  theme: proculLightTheme,
  darkTheme: proculDarkTheme,
  themeMode: ThemeMode.light,
  home: screen,
);

ModelCatalogController _catalog(
  ChatApi api, {
  Set<ModelInputModality> input = const {
    ModelInputModality.text,
    ModelInputModality.image,
  },
}) => ModelCatalogController(api: api)
  ..models = [
    ChatModel(
      slug: 'solo',
      name: 'Solo',
      isDefault: true,
      capabilities: ModelCapabilities(input: input),
    ),
  ];

MockClient _client({void Function(http.Request request)? onRequest}) =>
    MockClient((request) async {
      onRequest?.call(request);
      final path = request.url.path;

      if (path == '/v1/conversations' && request.method == 'GET') {
        return http.Response(jsonEncode({'conversations': <dynamic>[]}), 200);
      }
      if (path == '/v1/attachments' && request.method == 'POST') {
        return http.Response(
          jsonEncode({
            'id': 'a1',
            'fileName': 'photo.png',
            'contentType': 'image/png',
            'sizeBytes': _pngBytes.length,
            'createdAt': '2026-10-11T10:00:00Z',
          }),
          201,
        );
      }
      if (path == '/v1/attachments/a1' && request.method == 'GET') {
        return http.Response.bytes(
          _pngBytes,
          200,
          headers: {'content-type': 'image/png'},
        );
      }
      return http.Response('{}', 200);
    });

ChatController _chat(MockClient client) => ChatController(
  api: ChatApi(baseUrl: 'http://test', token: 'tok', client: client),
  store: FakeConversationStore(),
);

void main() {
  testWidgets('picking a file uploads it, shows a chip, and removes it', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1000, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    final requests = <http.Request>[];
    final chat = _chat(_client(onRequest: requests.add));
    final catalog = _catalog(chat.api);
    chat.setDefaultModel('solo');
    final picker = FakeAttachmentPicker();

    await tester.pumpWidget(
      _app(ChatScreen(chat: chat, catalog: catalog, picker: picker)),
    );
    await tester.pumpAndSettle();

    picker.next = PickedAttachment(
      bytes: _pngBytes,
      fileName: 'photo.png',
      contentType: 'image/png',
    );
    await tester.tap(find.byIcon(LucideIcons.paperclip));
    await tester.pumpAndSettle();

    expect(chat.pendingAttachments, hasLength(1));
    expect(chat.pendingAttachments.single.fileName, 'photo.png');
    expect(find.text('photo.png'), findsOneWidget);
    expect(
      requests.where(
        (r) => r.method == 'POST' && r.url.path == '/v1/attachments',
      ),
      hasLength(1),
    );

    // The remove button drops it from the composer.
    await tester.tap(find.byIcon(LucideIcons.x));
    await tester.pumpAndSettle();

    expect(chat.pendingAttachments, isEmpty);
    expect(find.text('photo.png'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('the model cannot read the file: rejected with a message', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1000, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    final requests = <http.Request>[];
    final chat = _chat(_client(onRequest: requests.add));
    // A text-only model: an image has no home.
    final catalog = _catalog(chat.api, input: {ModelInputModality.text});
    chat.setDefaultModel('solo');
    final picker = FakeAttachmentPicker();

    await tester.pumpWidget(
      _app(ChatScreen(chat: chat, catalog: catalog, picker: picker)),
    );
    await tester.pumpAndSettle();

    picker.next = PickedAttachment(
      bytes: _pngBytes,
      fileName: 'photo.png',
      contentType: 'image/png',
    );
    await tester.tap(find.byIcon(LucideIcons.paperclip));
    await tester.pumpAndSettle();

    expect(picker.pickCalls, 1);
    expect(chat.pendingAttachments, isEmpty);
    expect(chat.error, contains('image capability'));
    expect(
      requests.where(
        (r) => r.method == 'POST' && r.url.path == '/v1/attachments',
      ),
      isEmpty,
      reason: 'the file must not be uploaded when the model cannot read it',
    );
    expect(find.textContaining('image capability'), findsOneWidget);

    // Let the toast's 5s auto-dismiss timer fire so the test tears down clean.
    await tester.pump(const Duration(seconds: 6));
    await tester.pumpAndSettle();
  });

  testWidgets('cancelling the picker changes nothing', (tester) async {
    await tester.binding.setSurfaceSize(const Size(1000, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    final chat = _chat(_client());
    final catalog = _catalog(chat.api);
    chat.setDefaultModel('solo');
    final picker = FakeAttachmentPicker();

    await tester.pumpWidget(
      _app(ChatScreen(chat: chat, catalog: catalog, picker: picker)),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byIcon(LucideIcons.paperclip));
    await tester.pumpAndSettle();

    expect(picker.pickCalls, 1);
    expect(chat.pendingAttachments, isEmpty);
    expect(chat.error, isNull);
  });

  test('attachmentProblem gates by capability and size', () {
    const caps = {ModelInputModality.text, ModelInputModality.image};

    // Supported / always-sent / never-sent types pass.
    expect(
      attachmentProblem(
        fileName: 'a.png',
        contentType: 'image/png',
        sizeBytes: 10,
        capabilities: caps,
      ),
      isNull,
    );
    expect(
      attachmentProblem(
        fileName: 'a.txt',
        contentType: 'text/plain',
        sizeBytes: 10,
        capabilities: caps,
      ),
      isNull,
    );
    expect(
      attachmentProblem(
        fileName: 'a.mp4',
        contentType: 'video/mp4',
        sizeBytes: 10,
        capabilities: caps,
      ),
      isNull,
      reason: 'video is stored + shown, never sent, so it is not gated',
    );

    // A capability the model lacks is reported.
    expect(
      attachmentProblem(
        fileName: 'a.pdf',
        contentType: 'application/pdf',
        sizeBytes: 10,
        capabilities: caps,
      ),
      contains('file capability'),
    );

    // Oversized files are reported before upload.
    expect(
      attachmentProblem(
        fileName: 'a.png',
        contentType: 'image/png',
        sizeBytes: defaultMaxAttachmentBytes + 1,
        capabilities: caps,
      ),
      contains('limit'),
    );
  });
}
