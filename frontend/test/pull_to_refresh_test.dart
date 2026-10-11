import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:procul_chat_flutter/src/app_theme.dart';
import 'package:procul_chat_flutter/src/auth_api.dart';
import 'package:procul_chat_flutter/src/auth_controller.dart';
import 'package:procul_chat_flutter/src/chat_api.dart';
import 'package:procul_chat_flutter/src/chat_controller.dart';
import 'package:procul_chat_flutter/src/conversation_sidebar.dart';
import 'package:procul_chat_flutter/src/home_shell.dart';
import 'package:procul_chat_flutter/src/models_screen.dart';
import 'package:procul_chat_flutter/src/settings_controller.dart';
import 'package:shadcn_flutter/shadcn_flutter.dart';
import 'package:shadcn_flutter_material/shadcn_flutter_material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/fake_conversation_store.dart';
import 'support/fake_credential_store.dart';
import 'support/fake_server_store.dart';
import 'support/model_fixtures.dart';

/// A [ChatController] that records how often its refresh entry points are called.
class SpyChatController extends ChatController {
  SpyChatController({required super.api, super.store});

  int refreshConversationsCalls = 0;
  int reloadCalls = 0;
  int refreshAllCalls = 0;

  @override
  Future<void> refreshConversations() async {
    refreshConversationsCalls++;
    await super.refreshConversations();
  }

  @override
  Future<void> reloadActiveConversation() async {
    reloadCalls++;
    await super.reloadActiveConversation();
  }

  @override
  Future<void> refreshAll() async {
    refreshAllCalls++;
    await super.refreshAll();
  }
}

AuthController _auth() => AuthController(
  api: AuthApi(client: MockClient((_) async => http.Response('{}', 200))),
  credentials: FakeCredentialStore(),
  store: FakeServerStore(),
);

/// Drives the [RefreshTrigger]'s refresh path (as a completed pull would), then settles.
Future<void> _pullDown(WidgetTester tester, Finder trigger) async {
  final state = tester.state<RefreshTriggerState>(trigger);
  await state.refresh();
  await tester.pumpAndSettle();
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  testWidgets('pulling the sidebar list refreshes the conversations', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1200, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    final client = MockClient((request) async {
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
      return http.Response('{}', 200);
    });
    final chat = SpyChatController(
      api: ChatApi(baseUrl: 'http://test', token: 'tok', client: client),
      store: FakeConversationStore(),
    );
    final settings = SettingsController();

    await tester.pumpWidget(
      MaterialShadcnApp(
        theme: proculLightTheme,
        darkTheme: proculDarkTheme,
        themeMode: ThemeMode.light,
        home: HomeShell(chat: chat, settings: settings, auth: _auth()),
      ),
    );
    await tester.pumpAndSettle();

    final sidebarTrigger = find.descendant(
      of: find.byType(ConversationSidebar),
      matching: find.byType(RefreshTrigger),
    );
    expect(sidebarTrigger, findsOneWidget);

    await _pullDown(tester, sidebarTrigger);

    expect(chat.refreshConversationsCalls, greaterThanOrEqualTo(1));
  });

  testWidgets('pulling the chat pane reloads the active conversation', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1200, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    final client = MockClient(
      (_) async => http.Response('{"conversations":[]}', 200),
    );
    final chat = SpyChatController(
      api: ChatApi(baseUrl: 'http://test', token: 'tok', client: client),
      store: FakeConversationStore(),
    );
    final settings = SettingsController();

    await tester.pumpWidget(
      MaterialShadcnApp(
        theme: proculLightTheme,
        darkTheme: proculDarkTheme,
        themeMode: ThemeMode.light,
        home: HomeShell(chat: chat, settings: settings, auth: _auth()),
      ),
    );
    await tester.pumpAndSettle();

    final chatTrigger = find.ancestor(
      of: find.text('Send a message to start a new chat.'),
      matching: find.byType(RefreshTrigger),
    );
    expect(chatTrigger, findsOneWidget);

    await _pullDown(tester, chatTrigger);

    expect(chat.reloadCalls, greaterThanOrEqualTo(1));
  });

  testWidgets('the chat app-bar refresh button runs refreshAll', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1200, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    final client = MockClient(
      (_) async => http.Response('{"conversations":[]}', 200),
    );
    final chat = SpyChatController(
      api: ChatApi(baseUrl: 'http://test', token: 'tok', client: client),
      store: FakeConversationStore(),
    );

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

    await tester.tap(find.byIcon(LucideIcons.refreshCw).last);
    await tester.pumpAndSettle();

    expect(chat.refreshAllCalls, 1);
  });

  testWidgets('pulling the MCP server list refetches the status', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1100, 1000));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    var mcpRequests = 0;
    final client = MockClient((request) async {
      if (request.url.path == '/v1/mcp/servers') {
        mcpRequests++;
        return http.Response(
          jsonEncode({
            'servers': [
              {
                'name': 'github',
                'type': 'http',
                'url': 'https://example.com/mcp',
                'connected': true,
                'toolCount': 1,
                'tools': ['x'],
                'lastError': null,
                'lastConnectedAt': null,
              },
            ],
          }),
          200,
        );
      }
      return http.Response('{"conversations":[]}', 200);
    });
    final chat = ChatController(
      api: ChatApi(baseUrl: 'http://test', token: 'tok', client: client),
      store: FakeConversationStore(),
    );

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

    await tester.tap(find.text('Settings'));
    await tester.pumpAndSettle();
    expect(mcpRequests, 1);

    final mcpTrigger = find.ancestor(
      of: find.text('github'),
      matching: find.byType(RefreshTrigger),
    );
    expect(mcpTrigger, findsOneWidget);

    await _pullDown(tester, mcpTrigger);

    expect(mcpRequests, 2);
  });

  testWidgets('pulling the Models list refetches the catalog', (tester) async {
    await tester.binding.setSurfaceSize(const Size(1200, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    var modelRequests = 0;
    final client = MockClient((request) async {
      if (request.url.path == '/v1/models') {
        modelRequests++;
        return http.Response(jsonEncode(testSingleModelJson), 200);
      }
      return http.Response('{"conversations":[]}', 200);
    });
    final chat = ChatController(
      api: ChatApi(baseUrl: 'http://test', token: 'tok', client: client),
      store: FakeConversationStore(),
    );

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
    expect(modelRequests, 1);

    await tester.tap(find.text('Models'));
    await tester.pumpAndSettle();

    final modelsTrigger = find.descendant(
      of: find.byType(ModelsScreen),
      matching: find.byType(RefreshTrigger),
    );
    expect(modelsTrigger, findsOneWidget);

    await _pullDown(tester, modelsTrigger);

    expect(modelRequests, 2);
  });
}
