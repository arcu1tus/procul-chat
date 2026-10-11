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

/// Opens the settings dialog with a backend that answers conversations and MCP status.
Future<void> _openSettings(
  WidgetTester tester, {
  required http.Response Function(http.Request request) mcpResponse,
}) async {
  await tester.binding.setSurfaceSize(const Size(1100, 1000));
  addTearDown(() => tester.binding.setSurfaceSize(null));

  final client = MockClient((request) async {
    if (request.url.path == '/v1/mcp/servers') return mcpResponse(request);
    return http.Response('{"conversations":[]}', 200);
  });
  final chat = ChatController(
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

  await tester.tap(find.text('Settings'));
  await tester.pumpAndSettle();
}

Map<String, dynamic> _server({
  required String name,
  required bool connected,
  int toolCount = 0,
  String? lastError,
  String type = 'http',
}) => {
  'name': name,
  'type': type,
  'url': 'https://example.com/mcp',
  'connected': connected,
  'toolCount': toolCount,
  'tools': <String>[],
  'lastError': lastError,
  'lastConnectedAt': connected ? '2026-10-11T12:00:00Z' : null,
};

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  testWidgets('shows a summary and one row per server', (tester) async {
    await _openSettings(
      tester,
      mcpResponse: (_) => http.Response(
        jsonEncode({
          'servers': [
            _server(name: 'github', connected: true, toolCount: 2),
            _server(name: 'legacy', connected: false, type: 'sse'),
          ],
        }),
        200,
      ),
    );

    expect(find.text('Tools (MCP)'), findsOneWidget);
    expect(find.textContaining('1 of 2 servers online'), findsOneWidget);
    expect(find.textContaining('2 tools'), findsWidgets);
    expect(find.text('github'), findsOneWidget);
    expect(find.text('legacy'), findsOneWidget);
    expect(find.text('http'), findsOneWidget);
    expect(find.text('sse'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('shows the last error for an offline server', (tester) async {
    await _openSettings(
      tester,
      mcpResponse: (_) => http.Response(
        jsonEncode({
          'servers': [
            _server(
              name: 'github',
              connected: false,
              lastError: '401 Unauthorized',
            ),
          ],
        }),
        200,
      ),
    );

    expect(find.textContaining('0 of 1 servers online'), findsOneWidget);
    expect(find.text('401 Unauthorized'), findsOneWidget);
  });

  testWidgets('shows an empty state when nothing is configured', (
    tester,
  ) async {
    await _openSettings(
      tester,
      mcpResponse: (_) =>
          http.Response(jsonEncode({'servers': <dynamic>[]}), 200),
    );

    expect(find.text('No tool servers configured.'), findsOneWidget);
  });

  testWidgets('shows a request failure', (tester) async {
    await _openSettings(tester, mcpResponse: (_) => http.Response('boom', 500));

    expect(find.textContaining('Could not load tool servers'), findsOneWidget);
  });

  testWidgets('never renders headers or tokens', (tester) async {
    await _openSettings(
      tester,
      mcpResponse: (_) => http.Response(
        jsonEncode({
          'servers': [
            {
              ..._server(name: 'github', connected: true, toolCount: 1),
              // A hypothetical leak the client must ignore.
              'headers': {'Authorization': 'Bearer SUPERSECRET'},
            },
          ],
        }),
        200,
      ),
    );

    expect(find.textContaining('SUPERSECRET'), findsNothing);
    expect(find.textContaining('Authorization'), findsNothing);
  });
}
