import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:procul_chat_flutter/src/app_theme.dart';
import 'package:procul_chat_flutter/src/auth_api.dart';
import 'package:procul_chat_flutter/src/auth_controller.dart';
import 'package:procul_chat_flutter/src/chat_api.dart';
import 'package:procul_chat_flutter/src/chat_controller.dart';
import 'package:procul_chat_flutter/src/home_shell.dart';
import 'package:procul_chat_flutter/src/settings_controller.dart';
import 'package:shadcn_flutter/shadcn_flutter.dart';
import 'package:shadcn_flutter_material/shadcn_flutter_material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/fake_conversation_store.dart';
import 'support/fake_credential_store.dart';
import 'support/fake_server_store.dart';

AuthController _auth() => AuthController(
  api: AuthApi(client: MockClient((_) async => http.Response('{}', 200))),
  credentials: FakeCredentialStore(),
  store: FakeServerStore(),
);

MockClient _client() => MockClient((request) async {
  if (request.url.path == '/v1/conversations') {
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
  if (request.url.path == '/v1/conversations/c1/messages') {
    return http.Response('{"messages":[]}', 200);
  }
  return http.Response('{}', 200);
});

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  testWidgets('tapping the tile ellipsis opens the rename/delete menu', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1200, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    final chat = ChatController(
      api: ChatApi(baseUrl: 'http://test', token: 'tok', client: _client()),
      store: FakeConversationStore('c1'),
    );
    await chat.init();
    await tester.pumpWidget(
      MaterialShadcnApp(
        theme: proculLightTheme,
        darkTheme: proculDarkTheme,
        themeMode: ThemeMode.light,
        home: HomeShell(
          chat: chat,
          settings: SettingsController(),
          auth: _auth(),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('First'), findsWidgets);
    await tester.tap(find.byIcon(LucideIcons.ellipsis).first);
    await tester.pumpAndSettle();

    expect(find.text('Rename'), findsOneWidget);
    expect(find.text('Delete'), findsOneWidget);

    // Tapping Rename runs the existing dialog.
    await tester.tap(find.text('Rename'));
    await tester.pumpAndSettle();
    expect(find.text('Rename chat'), findsOneWidget);
  });

  testWidgets('the narrow chat-header overflow opens the chat menu', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(420, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    final chat = ChatController(
      api: ChatApi(baseUrl: 'http://test', token: 'tok', client: _client()),
      store: FakeConversationStore('c1'),
    );
    await chat.init();
    await tester.pumpWidget(
      MaterialShadcnApp(
        theme: proculLightTheme,
        darkTheme: proculDarkTheme,
        themeMode: ThemeMode.light,
        home: HomeShell(
          chat: chat,
          settings: SettingsController(),
          auth: _auth(),
        ),
      ),
    );
    await tester.pumpAndSettle();

    // Narrow: the app bar collapses to a single overflow button.
    await tester.tap(find.byKey(const Key('chat-options')));
    await tester.pumpAndSettle();

    expect(find.text('Refresh'), findsOneWidget);
    expect(find.text('Rename'), findsOneWidget);
    expect(find.text('Delete'), findsOneWidget);
  });

  testWidgets('the sidebar refresh shows a busy state and refetches', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1200, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    var listCalls = 0;
    final gate = Completer<void>();
    addTearDown(() {
      if (!gate.isCompleted) gate.complete();
    });
    final client = MockClient((request) async {
      if (request.url.path == '/v1/conversations') {
        listCalls++;
        if (listCalls > 1) await gate.future;
        return http.Response(jsonEncode({'conversations': <dynamic>[]}), 200);
      }
      return http.Response('{}', 200);
    });
    final chat = ChatController(
      api: ChatApi(baseUrl: 'http://test', token: 'tok', client: client),
      store: FakeConversationStore(),
    );
    await chat.init();

    await tester.pumpWidget(
      MaterialShadcnApp(
        theme: proculLightTheme,
        darkTheme: proculDarkTheme,
        themeMode: ThemeMode.light,
        home: HomeShell(
          chat: chat,
          settings: SettingsController(),
          auth: _auth(),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(listCalls, 1);

    await tester.tap(find.bySemanticsLabel('Refresh chats'));
    await tester.pump();

    // While the refresh is in flight the button shows a spinner.
    expect(chat.isRefreshing, isTrue);
    expect(
      find.descendant(
        of: find.bySemanticsLabel('Refresh chats'),
        matching: find.byType(CircularProgressIndicator),
      ),
      findsOneWidget,
    );

    gate.complete();
    await tester.pumpAndSettle();
    expect(listCalls, 2);
    expect(chat.isRefreshing, isFalse);
    expect(tester.takeException(), isNull);
  });

  testWidgets('a resumed lifecycle refreshes from the server', (tester) async {
    await tester.binding.setSurfaceSize(const Size(1200, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    var listCalls = 0;
    final client = MockClient((request) async {
      if (request.url.path == '/v1/conversations') {
        listCalls++;
        return http.Response(jsonEncode({'conversations': <dynamic>[]}), 200);
      }
      return http.Response('{}', 200);
    });
    final chat = ChatController(
      api: ChatApi(baseUrl: 'http://test', token: 'tok', client: client),
      store: FakeConversationStore(),
    );
    await chat.init();
    expect(listCalls, 1);

    await tester.pumpWidget(
      MaterialShadcnApp(
        theme: proculLightTheme,
        darkTheme: proculDarkTheme,
        themeMode: ThemeMode.light,
        home: HomeShell(
          chat: chat,
          settings: SettingsController(),
          auth: _auth(),
        ),
      ),
    );
    await tester.pumpAndSettle();

    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    await tester.pump();
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pumpAndSettle();

    expect(listCalls, greaterThan(1));
    expect(tester.takeException(), isNull);
  });

  testWidgets('a resume does not sync while a reply streams', (tester) async {
    await tester.binding.setSurfaceSize(const Size(1200, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    var listCalls = 0;
    final client = MockClient((request) async {
      if (request.url.path == '/v1/conversations') {
        listCalls++;
        return http.Response(jsonEncode({'conversations': <dynamic>[]}), 200);
      }
      return http.Response('{}', 200);
    });
    final chat = ChatController(
      api: ChatApi(baseUrl: 'http://test', token: 'tok', client: client),
      store: FakeConversationStore(),
    );
    await chat.init();
    expect(listCalls, 1);

    await tester.pumpWidget(
      MaterialShadcnApp(
        theme: proculLightTheme,
        darkTheme: proculDarkTheme,
        themeMode: ThemeMode.light,
        home: HomeShell(
          chat: chat,
          settings: SettingsController(),
          auth: _auth(),
        ),
      ),
    );
    await tester.pumpAndSettle();

    // While a reply streams the shell must not resync (it could clobber it).
    chat.isStreaming = true;
    chat.setDefaultModel(
      'busy/model',
    ); // notify listeners so the shell rebuilds
    await tester.pump();

    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    await tester.pump();
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    // Bounded pumps: while "streaming" a widget keeps an animation alive, so
    // `pumpAndSettle` would never settle. The assertion is synchronous anyway.
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    expect(listCalls, 1);
    expect(tester.takeException(), isNull);
  });
}
