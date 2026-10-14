import 'dart:async';
import 'dart:convert';
import 'dart:ui' show ViewFocusDirection, ViewFocusEvent, ViewFocusState;

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:procul_chat_flutter/src/app_theme.dart';
import 'package:procul_chat_flutter/src/attachments.dart';
import 'package:procul_chat_flutter/src/chat_api.dart';
import 'package:procul_chat_flutter/src/chat_controller.dart';
import 'package:procul_chat_flutter/src/chat_screen.dart';
import 'package:procul_chat_flutter/src/media_input.dart';
import 'package:procul_chat_flutter/src/widgets/media_drop_target.dart';
import 'package:shadcn_flutter/shadcn_flutter.dart';

import 'support/fake_attachment_picker.dart';
import 'support/fake_conversation_store.dart';
import 'support/media_fixture.dart';

Future<void> _pump(WidgetTester tester) async {
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 300));
  await tester.pump(const Duration(milliseconds: 300));
}

Future<void> _focusView(WidgetTester tester) async {
  if (!kIsWeb) return;
  tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
  tester.binding.platformDispatcher.onViewFocusChange?.call(
    ViewFocusEvent(
      viewId: tester.view.viewId,
      state: ViewFocusState.focused,
      direction: ViewFocusDirection.undefined,
    ),
  );
  await _pump(tester);
  // Headless Chrome can return focus to the route while attaching its first
  // editor. Prime the connection before testing later taps and state changes.
  _editable(tester).focusNode.requestFocus();
  FocusManager.instance.applyFocusChangesIfNeeded();
  await _pump(tester);
}

EditableText _editable(WidgetTester tester) => tester.widget<EditableText>(
  find.descendant(
    of: find.byKey(const Key('message-input')),
    matching: find.byType(EditableText),
  ),
);

Future<void> _type(WidgetTester tester, String text) async {
  await tester.tap(find.byKey(const Key('message-input')));
  await _pump(tester);
  expect(_editable(tester).focusNode.hasFocus, isTrue);
  expect(tester.testTextInput.hasAnyClients, isTrue);
  tester.testTextInput.enterText(text);
  await tester.pump();
  expect(_editable(tester).controller.text, text);
}

void main() {
  for (final scenario in ['fresh chat', 'after upload', 'during upload']) {
    testWidgets('empty composer accepts typing: $scenario', (tester) async {
      final response = Completer<http.Response>();
      final chat = withMediaPolicy(
        ChatController(
          api: ChatApi(
            baseUrl: 'http://test',
            token: 'test',
            client: MockClient((_) => response.future),
          ),
          store: FakeConversationStore(),
        ),
      );
      addTearDown(chat.dispose);
      final picker = FakeAttachmentPicker()
        ..filesResult = [
          PickedAttachment(
            bytes: Uint8List.fromList(utf8.encode('hi')),
            fileName: 'notes.txt',
            contentType: 'text/plain',
          ),
        ];
      await tester.pumpWidget(
        ShadcnApp(
          theme: proculLightTheme,
          home: ChatScreen(chat: chat, picker: picker),
        ),
      );
      await _pump(tester);
      await _focusView(tester);
      if (scenario != 'fresh chat') {
        await tester.tap(find.byIcon(LucideIcons.paperclip));
        await _pump(tester);
        await tester.tap(find.text('Files'));
        await _pump(tester);
        expect(chat.isUploadingAttachment, isTrue);
        if (scenario == 'during upload') {
          await _type(tester, 'While uploading');
          await tester.sendKeyEvent(LogicalKeyboardKey.enter);
          await tester.pump();
          expect(chat.messages, isEmpty);
        }
        response.complete(
          http.Response(
            '{"id":"a","fileName":"notes.txt","contentType":"text/plain","sizeBytes":2}',
            201,
          ),
        );
        await _pump(tester);
        expect(chat.isUploadingAttachment, isFalse);
        expect(chat.pendingAttachments, hasLength(1));
        if (scenario == 'after upload') {
          expect(_editable(tester).controller.text, isEmpty);
        }
      }

      // Real taps must open an input connection. tester.enterText would force
      // focus and hide failures in pointer handling.
      await _type(tester, 'Can type');
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    });
  }

  testWidgets('media reads preserve focus and allow drafting without sending', (
    tester,
  ) async {
    final chat = withMediaPolicy(
      ChatController(
        api: ChatApi(baseUrl: 'http://test', token: 'test'),
      ),
    );
    addTearDown(chat.dispose);
    await tester.pumpWidget(
      ShadcnApp(
        theme: proculLightTheme,
        home: ChatScreen(chat: chat),
      ),
    );
    await _focusView(tester);
    await _type(tester, 'Before');
    final payload = Completer<MediaInputPayload>();
    tester
        .widget<MediaDropTarget>(find.byType(MediaDropTarget))
        .onReceive(payload.future);
    await _pump(tester);
    expect(chat.isReadingMedia, isTrue);
    expect(_editable(tester).focusNode.hasFocus, isTrue);
    await _type(tester, 'While reading');
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pump();
    expect(chat.messages, isEmpty);
    payload.complete(const MediaInputPayload());
    await _pump(tester);
    expect(chat.isReadingMedia, isFalse);
    expect(_editable(tester).controller.text, 'While reading');
    await _type(tester, 'After reading');
    await tester.pumpWidget(const SizedBox.shrink());
  });

  for (final rejected in [false, true]) {
    testWidgets('can draft while waiting for a reply (rejected: $rejected)', (
      tester,
    ) async {
      final response = Completer<http.Response>();
      var requests = 0;
      final chat = ChatController(
        api: ChatApi(
          baseUrl: 'http://test',
          token: 'test',
          client: MockClient((_) {
            requests++;
            return response.future;
          }),
        ),
        store: FakeConversationStore(),
      );
      addTearDown(chat.dispose);
      await tester.pumpWidget(
        ShadcnApp(
          theme: proculLightTheme,
          home: ChatScreen(chat: chat),
        ),
      );
      await _focusView(tester);
      await _type(tester, 'First message');
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await _pump(tester);
      expect(chat.isStreaming, isTrue);
      expect(_editable(tester).focusNode.hasFocus, isTrue);
      await _type(tester, 'Next draft');
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pump();
      expect(requests, 1);
      expect(_editable(tester).controller.text, 'Next draft');
      await tester.runAsync(() async {
        final finished = Completer<void>();
        void onChanged() {
          if (!chat.isStreaming && !finished.isCompleted) finished.complete();
        }

        chat.addListener(onChanged);
        try {
          response.complete(
            rejected
                ? http.Response('Rejected', 400)
                : http.Response('data: {"value":{"type":"done"}}\n\n', 200),
          );
          // Error response bodies use a browser event-loop stream; let it
          // complete outside the test's fake clock before pumping the UI.
          await finished.future.timeout(const Duration(seconds: 5));
        } finally {
          chat.removeListener(onChanged);
        }
      });
      await _pump(tester);
      expect(chat.isStreaming, isFalse);
      expect(_editable(tester).controller.text, contains('Next draft'));
      if (rejected) {
        expect(_editable(tester).controller.text, contains('First message'));
        await tester.pump(const Duration(seconds: 6));
        await _pump(tester);
      }
      await _type(tester, 'After reply');
      await tester.pumpWidget(const SizedBox.shrink());
    });
  }
}
