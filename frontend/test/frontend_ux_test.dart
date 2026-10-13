import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:procul_chat_flutter/src/app_theme.dart';
import 'package:procul_chat_flutter/src/auth_api.dart';
import 'package:procul_chat_flutter/src/auth_controller.dart';
import 'package:procul_chat_flutter/src/chat_api.dart';
import 'package:procul_chat_flutter/src/chat_controller.dart';
import 'package:procul_chat_flutter/src/chat_screen.dart';
import 'package:procul_chat_flutter/src/conversation_sidebar.dart';
import 'package:procul_chat_flutter/src/server_form.dart';
import 'package:shadcn_flutter/shadcn_flutter.dart';
import 'package:shadcn_flutter_material/shadcn_flutter_material.dart';

import 'support/fake_conversation_store.dart';
import 'support/fake_credential_store.dart';
import 'support/fake_server_store.dart';

Widget _app(Widget child, {bool reduced = false}) => MaterialShadcnApp(
  theme: proculLightTheme,
  builder: (context, child) => MediaQuery(
    data: MediaQuery.of(context).copyWith(disableAnimations: reduced),
    child: child!,
  ),
  home: child,
);

void main() {
  testWidgets('chat search filters titles and clearing restores the list', (
    tester,
  ) async {
    final chat = ChatController(
      api: ChatApi(
        baseUrl: 'http://test',
        token: 'tok',
        client: MockClient(
          (_) async => http.Response(
            jsonEncode({
              'conversations': [
                {
                  'id': 'c1',
                  'title': 'Weekend plans',
                  'createdAt': '2026-10-11T10:00:00Z',
                },
                {
                  'id': 'c2',
                  'title': 'Dinner ideas',
                  'createdAt': '2026-10-11T10:00:00Z',
                },
              ],
            }),
            200,
          ),
        ),
      ),
      store: FakeConversationStore(),
    );
    addTearDown(chat.dispose);
    await chat.init();
    await tester.pumpWidget(
      _app(
        Center(
          child: SizedBox(width: 280, child: ConversationSidebar(chat: chat)),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.enterText(find.byKey(const Key('chat-search')), ' WEEKEND ');
    await tester.pumpAndSettle();
    expect(find.text('Weekend plans'), findsOneWidget);
    expect(find.text('Dinner ideas'), findsNothing);
    // Search doesn't change the actual conversation list or active chat.
    expect(chat.conversations, hasLength(2));
    expect(chat.activeConversationId, isNull);

    await tester.enterText(find.byKey(const Key('chat-search')), 'missing');
    await tester.pumpAndSettle();
    expect(find.textContaining('No matching chats'), findsOneWidget);
    await tester.tap(find.bySemanticsLabel('Clear search'));
    await tester.pumpAndSettle();
    expect(find.text('Weekend plans'), findsOneWidget);
    expect(find.text('Dinner ideas'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  for (final reduced in [false, true]) {
    testWidgets(
      'a starter fills and focuses the composer without sending (reduced: $reduced)',
      (tester) async {
        var requests = 0;
        final chat = ChatController(
          api: ChatApi(
            baseUrl: 'http://test',
            token: 'tok',
            client: MockClient((_) async {
              requests++;
              return http.Response('{}', 200);
            }),
          ),
          store: FakeConversationStore(),
        );
        addTearDown(chat.dispose);
        await tester.pumpWidget(_app(ChatScreen(chat: chat), reduced: reduced));
        await tester.pumpAndSettle();
        await tester.ensureVisible(find.text('Write something'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('Write something'));
        await tester.pumpAndSettle();

        final input = tester.widget<TextField>(
          find.byKey(const Key('message-input')),
        );
        expect(input.controller!.text, 'Help me write a message about ');
        expect(
          input.controller!.selection.baseOffset,
          input.controller!.text.length,
        );
        expect(input.focusNode!.hasFocus, isTrue);
        expect(requests, 0);
        expect(chat.messages, isEmpty);
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets(
    'send requires text and waits for attachments to finish uploading',
    (tester) async {
      var requests = 0;
      final chat = ChatController(
        api: ChatApi(
          baseUrl: 'http://test',
          token: 'tok',
          client: MockClient((_) async {
            requests++;
            return http.Response('{}', 200);
          }),
        ),
        store: FakeConversationStore(),
      );
      addTearDown(chat.dispose);
      await tester.pumpWidget(_app(ChatScreen(chat: chat)));
      await tester.pumpAndSettle();
      PrimaryButton send() =>
          tester.widget<PrimaryButton>(find.byType(PrimaryButton));
      expect(send().onPressed, isNull);
      await tester.enterText(find.byKey(const Key('message-input')), '  ');
      await tester.pumpAndSettle();
      expect(send().onPressed, isNull);
      await tester.enterText(
        find.byKey(const Key('message-input')),
        'Read this file',
      );
      await tester.pumpAndSettle();
      expect(send().onPressed, isNotNull);
      chat.isUploadingAttachment = true;
      chat.notifyListeners();
      await tester.pump();
      expect(send().onPressed, isNull);
      await tester.testTextInput.receiveAction(TextInputAction.send);
      await tester.pump();
      expect(requests, 0);
      expect(
        tester
            .widget<TextField>(find.byKey(const Key('message-input')))
            .controller!
            .text,
        'Read this file',
      );
      chat.isUploadingAttachment = false;
      chat.notifyListeners();
      await tester.pumpAndSettle();
      expect(send().onPressed, isNotNull);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('password visibility preserves the entered password', (
    tester,
  ) async {
    final auth = AuthController(
      api: AuthApi(client: MockClient((_) async => http.Response('{}', 200))),
      credentials: FakeCredentialStore(),
      store: FakeServerStore(),
    );
    addTearDown(auth.dispose);
    await tester.pumpWidget(_app(Scaffold(child: ServerForm(auth: auth))));
    await tester.pumpAndSettle();
    final password = find.widgetWithText(TextField, 'Password');
    await tester.enterText(password, 'a secret');
    expect(tester.widget<TextField>(password).obscureText, isTrue);
    await tester.tap(find.bySemanticsLabel('Show password'));
    await tester.pumpAndSettle();
    expect(tester.widget<TextField>(password).obscureText, isFalse);
    expect(tester.widget<TextField>(password).controller!.text, 'a secret');
    await tester.tap(find.bySemanticsLabel('Hide password'));
    await tester.pumpAndSettle();
    expect(tester.widget<TextField>(password).obscureText, isTrue);
    expect(tester.takeException(), isNull);
  });
}
