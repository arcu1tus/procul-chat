import 'support/policy_chat_api.dart';

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:procul_chat_flutter/src/app_theme.dart';
import 'package:procul_chat_flutter/src/auth_api.dart';
import 'package:procul_chat_flutter/src/auth_controller.dart';
import 'package:procul_chat_flutter/src/chat_controller.dart';
import 'package:procul_chat_flutter/src/home_shell.dart';
import 'package:procul_chat_flutter/src/server_profile.dart';
import 'package:procul_chat_flutter/src/settings_controller.dart';
import 'package:shadcn_flutter/shadcn_flutter.dart';
import 'package:shadcn_flutter_material/shadcn_flutter_material.dart';

import 'support/fake_conversation_store.dart';
import 'support/fake_credential_store.dart';
import 'support/fake_server_store.dart';

MockClient _authClient() => MockClient((request) async {
  final body = jsonDecode(request.body) as Map<String, dynamic>;
  if (body['password'] != 'pw') return http.Response('unauthorized', 401);
  return http.Response(
    jsonEncode({'token': 'tok-1', 'expiresAt': '2026-10-11T10:00:00Z'}),
    200,
  );
});

AuthController _auth({
  FakeCredentialStore? credentials,
  FakeServerStore? store,
}) => AuthController(
  api: AuthApi(client: _authClient()),
  credentials: credentials ?? FakeCredentialStore(),
  store: store ?? FakeServerStore(),
);

Future<void> _pumpShell(WidgetTester tester, AuthController auth) async {
  await tester.binding.setSurfaceSize(const Size(1100, 1000));
  addTearDown(() => tester.binding.setSurfaceSize(null));

  final client = MockClient(
    (request) async => http.Response('{"conversations":[]}', 200),
  );
  final chat = ChatController(
    api: PolicyChatApi(
      baseUrl: 'http://test',
      token: 'test-token',
      client: client,
    ),
    store: FakeConversationStore(),
  );
  final settings = SettingsController();

  await tester.pumpWidget(
    MaterialShadcnApp(
      theme: proculLightTheme,
      darkTheme: proculDarkTheme,
      themeMode: ThemeMode.light,
      home: HomeShell(chat: chat, settings: settings, auth: auth),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('the add-server modal saves a profile and signs in', (
    tester,
  ) async {
    final auth = _auth();
    await _pumpShell(tester, auth);

    await tester.tap(find.text('Settings'));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Add server'));
    await tester.pumpAndSettle();

    // Name (optional), Base URL, Password.
    final urlField = find.widgetWithText(TextField, 'Server URL');
    final passwordField = find.widgetWithText(TextField, 'Password');
    expect(urlField, findsOneWidget);
    expect(passwordField, findsOneWidget);

    await tester.enterText(urlField, 'http://a.test');
    await tester.enterText(passwordField, 'pw');
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();

    expect(auth.error, isNull, reason: 'unexpected error: ${auth.error}');
    expect(auth.profiles, hasLength(1));
    expect(auth.profiles.single.baseUrl, 'http://a.test');
    expect(auth.active, isNotNull);
    expect(tester.takeException(), isNull);
  });

  testWidgets('the remove-server confirm removes the active profile', (
    tester,
  ) async {
    const profile = ServerProfile(
      id: 'p1',
      name: 'Home',
      baseUrl: 'http://a.test',
    );
    final credentials = FakeCredentialStore()..tokens['p1'] = 'stored';
    final store = FakeServerStore(profiles: [profile], activeId: 'p1');
    final auth = _auth(credentials: credentials, store: store);
    await auth.init();

    await _pumpShell(tester, auth);

    await tester.tap(find.text('Settings'));
    await tester.pumpAndSettle();
    expect(find.text('Home'), findsWidgets);

    await tester.tap(find.text('Remove'));
    await tester.pumpAndSettle();

    // The confirm dialog's destructive button (the settings one is behind it).
    await tester.tap(find.text('Remove').last);
    await tester.pumpAndSettle();

    expect(auth.profiles, isEmpty);
    expect(auth.active, isNull);
    expect(credentials.tokens, isEmpty);
  });
}
