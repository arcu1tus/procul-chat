import 'dart:convert';

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
import 'package:shadcn_flutter/shadcn_flutter.dart';

import 'support/fake_conversation_store.dart';
import 'support/media_fixture.dart';

class _PasteSource implements MediaInputSource {
  int calls = 0;
  @override
  Future<MediaInputPayload> readClipboard({
    required int maxBytes,
    required int maxItems,
  }) async {
    calls++;
    return MediaInputPayload(
      text: 'pasted',
      files: [
        PickedAttachment(
          bytes: Uint8List.fromList(utf8.encode('hi')),
          fileName: 'notes.txt',
          contentType: 'text/plain',
        ),
      ],
    );
  }
}

void main() {
  testWidgets(
    'Ctrl+V preserves selection replacement and queues mixed media once',
    (tester) async {
      final source = _PasteSource();
      final chat = withMediaPolicy(
        ChatController(
          api: ChatApi(
            baseUrl: 'http://test',
            token: 'test',
            client: MockClient((request) async {
              return http.Response(
                '{"id":"a","fileName":"notes.txt","contentType":"text/plain","sizeBytes":2}',
                201,
              );
            }),
          ),
          store: FakeConversationStore(),
        ),
      );
      addTearDown(chat.dispose);
      await tester.pumpWidget(
        ShadcnApp(
          theme: proculLightTheme,
          home: ChatScreen(chat: chat, mediaInput: source),
        ),
      );
      final field = find.byKey(const Key('message-input'));
      await tester.enterText(field, 'before selected after');
      final editable = tester.widget<EditableText>(
        find.descendant(of: field, matching: find.byType(EditableText)),
      );
      editable.controller.selection = const TextSelection(
        baseOffset: 7,
        extentOffset: 15,
      );
      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyV);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(source.calls, 1);
      expect(editable.controller.text, 'before pasted after');
      expect(editable.focusNode.hasFocus, isTrue);
      expect(chat.pendingAttachments.single.fileName, 'notes.txt');
      expect(find.text('notes.txt'), findsOneWidget);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );
}
