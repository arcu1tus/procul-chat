import 'support/media_fixture.dart';

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

final _textBytes = Uint8List.fromList(utf8.encode('hello'));

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

MockClient _client({void Function(http.Request request)? onRequest}) {
  var uploads = 0;
  return MockClient((request) async {
    onRequest?.call(request);
    final path = request.url.path;

    if (path == '/v1/conversations' && request.method == 'GET') {
      return http.Response(jsonEncode({'conversations': <dynamic>[]}), 200);
    }
    if (path == '/v1/attachments' && request.method == 'POST') {
      uploads++;
      return http.Response(
        jsonEncode({
          'id': 'a$uploads',
          'fileName': 'photo.png',
          'contentType': 'image/png',
          'sizeBytes': _pngBytes.length,
          'createdAt': '2026-10-11T10:00:00Z',
        }),
        201,
      );
    }
    if (path.startsWith('/v1/attachments/') && request.method == 'GET') {
      return http.Response.bytes(
        _pngBytes,
        200,
        headers: {'content-type': 'image/png'},
      );
    }
    return http.Response('{}', 200);
  });
}

ChatController _chat(MockClient client) => withMediaPolicy(
  ChatController(
    api: ChatApi(baseUrl: 'http://test', token: 'tok', client: client),
    store: FakeConversationStore(),
  ),
);

void main() {
  setUp(() {
    // The `image_picker` platform channel is not registered under flutter_test,
    // so pin camera availability per test.
    AttachmentSources.debugCameraSupported = false;
  });
  tearDown(() => AttachmentSources.debugCameraSupported = null);

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

    picker.filesResult = [
      PickedAttachment(
        bytes: _pngBytes,
        fileName: 'photo.png',
        contentType: 'image/png',
      ),
    ];

    // The paperclip opens the source menu (Gallery + Files on desktop).
    await tester.tap(find.byIcon(LucideIcons.paperclip));
    await tester.pumpAndSettle();
    expect(find.text('Gallery'), findsOneWidget);
    expect(find.text('Files'), findsOneWidget);
    expect(find.text('Camera'), findsNothing);

    await tester.tap(find.text('Files'));
    await tester.pumpAndSettle();

    expect(chat.pendingAttachments, hasLength(1));
    expect(chat.pendingAttachments.single.fileName, 'photo.png');
    expect(find.text('photo.png'), findsOneWidget);

    // The picker only offered types the active model (text + image) can read.
    expect(picker.lastAllowedExtensions, contains('png'));
    expect(picker.lastAllowedExtensions, contains('txt'));
    expect(picker.lastAllowedExtensions, isNot(contains('pdf')));
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

  testWidgets('the model cannot read images: camera and gallery are hidden', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1000, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    AttachmentSources.debugCameraSupported = true;
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

    picker.filesResult = [
      PickedAttachment(
        bytes: _pngBytes,
        fileName: 'photo.png',
        contentType: 'image/png',
      ),
    ];
    // Only Files remains, so the paperclip opens it directly (no menu).
    await tester.tap(find.byIcon(LucideIcons.paperclip));
    await tester.pumpAndSettle();

    expect(picker.filesCalls, 1);
    expect(picker.cameraCalls, 0);
    expect(picker.galleryCalls, 0);
    // The picker was restricted to text files, so an image could not be chosen.
    expect(picker.lastAllowedExtensions, contains('txt'));
    expect(picker.lastAllowedExtensions, isNot(contains('png')));
    // Even if the platform lets one through, it is rejected before upload.
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
    await tester.tap(find.text('Files'));
    await tester.pumpAndSettle();

    expect(picker.filesCalls, 1);
    expect(chat.pendingAttachments, isEmpty);
    expect(chat.error, isNull);
  });

  testWidgets('camera captures and uploads where the platform supports it', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1000, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    AttachmentSources.debugCameraSupported = true;
    final chat = _chat(_client());
    final catalog = _catalog(chat.api);
    chat.setDefaultModel('solo');
    final picker = FakeAttachmentPicker();

    await tester.pumpWidget(
      _app(ChatScreen(chat: chat, catalog: catalog, picker: picker)),
    );
    await tester.pumpAndSettle();

    picker.cameraResult = PickedAttachment(
      bytes: _pngBytes,
      fileName: 'shot.png',
      contentType: 'image/png',
    );

    await tester.tap(find.byIcon(LucideIcons.paperclip));
    await tester.pumpAndSettle();
    expect(find.text('Camera'), findsOneWidget);
    await tester.tap(find.text('Camera'));
    await tester.pumpAndSettle();

    expect(picker.cameraCalls, 1);
    expect(chat.pendingAttachments, hasLength(1));
    expect(chat.pendingAttachments.single.fileName, 'photo.png');
  });

  testWidgets('gallery multi-select uploads every file', (tester) async {
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

    picker.galleryResult = [
      PickedAttachment(
        bytes: _pngBytes,
        fileName: 'one.png',
        contentType: 'image/png',
      ),
      PickedAttachment(
        bytes: _pngBytes,
        fileName: 'two.png',
        contentType: 'image/png',
      ),
    ];

    await tester.tap(find.byIcon(LucideIcons.paperclip));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Gallery'));
    await tester.pumpAndSettle();

    expect(picker.galleryCalls, 1);
    expect(chat.pendingAttachments, hasLength(2));
    // The mock upload endpoint echoes a fixed file name, so both chips show it.
    expect(find.text('photo.png'), findsNWidgets(2));
  });

  testWidgets('a single failing upload keeps the rest (multi-upload)', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1000, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    // The backend rejects the second upload.
    var uploads = 0;
    final client = MockClient((request) async {
      if (request.url.path == '/v1/attachments' && request.method == 'POST') {
        uploads++;
        if (uploads == 2) return http.Response('too big', 413);
        return http.Response(
          jsonEncode({
            'id': 'a$uploads',
            'fileName': 'ok.txt',
            'contentType': 'text/plain',
            'sizeBytes': 5,
            'createdAt': '2026-10-11T10:00:00Z',
          }),
          201,
        );
      }
      return http.Response('{"conversations":[]}', 200);
    });
    final chat = _chat(client);
    final catalog = _catalog(chat.api);
    chat.setDefaultModel('solo');
    final picker = FakeAttachmentPicker();

    await tester.pumpWidget(
      _app(ChatScreen(chat: chat, catalog: catalog, picker: picker)),
    );
    await tester.pumpAndSettle();

    picker.filesResult = [
      PickedAttachment(
        bytes: _textBytes,
        fileName: 'ok.txt',
        contentType: 'text/plain',
      ),
      PickedAttachment(
        bytes: _textBytes,
        fileName: 'bad.txt',
        contentType: 'text/plain',
      ),
    ];

    await tester.tap(find.byIcon(LucideIcons.paperclip));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Files'));
    await tester.pumpAndSettle();

    expect(chat.pendingAttachments, hasLength(1));
    expect(chat.pendingAttachments.single.fileName, 'ok.txt');
    expect(chat.error, isNotNull);

    await tester.pump(const Duration(seconds: 6));
    await tester.pumpAndSettle();
  });

  testWidgets('the attachment sources helper follows the platform', (
    tester,
  ) async {
    AttachmentSources.debugCameraSupported = false;
    expect(AttachmentSources.available(), [
      AttachmentSource.gallery,
      AttachmentSource.files,
    ]);
    AttachmentSources.debugCameraSupported = true;
    expect(AttachmentSources.available(), [
      AttachmentSource.camera,
      AttachmentSource.gallery,
      AttachmentSource.files,
    ]);
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
      isNotNull,
      reason: 'the adapter cannot transmit video',
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

  test('allowedExtensionsForCapabilities follows the model modalities', () {
    // Text is always offered; video never is (no model can receive it).
    final textOnly = allowedExtensionsForCapabilities({
      ModelInputModality.text,
    });
    expect(textOnly, contains('txt'));
    expect(textOnly, isNot(contains('png')));
    expect(textOnly, isNot(contains('mp4')));

    final everything = allowedExtensionsForCapabilities({
      ModelInputModality.text,
      ModelInputModality.image,
      ModelInputModality.file,
      ModelInputModality.audio,
      ModelInputModality.video,
    });
    expect(everything, containsAll(['png', 'pdf', 'mp3', 'txt']));
    expect(everything, isNot(contains('mp4')));
  });
}
