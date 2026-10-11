import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:procul_chat_flutter/src/app_theme.dart';
import 'package:procul_chat_flutter/src/auth_api.dart';
import 'package:procul_chat_flutter/src/auth_controller.dart';
import 'package:procul_chat_flutter/src/connect_screen.dart';
import 'package:procul_chat_flutter/src/server_profile.dart';
import 'package:shadcn_flutter/shadcn_flutter.dart';
import 'package:shadcn_flutter_material/shadcn_flutter_material.dart';

import 'support/fake_credential_store.dart';
import 'support/fake_server_store.dart';

MockClient _authClient({String password = 'pw', String token = 'tok-1'}) {
  return MockClient((request) async {
    final body = jsonDecode(request.body) as Map<String, dynamic>;
    if (body['password'] != password) {
      return http.Response('unauthorized', 401);
    }
    return http.Response(
      jsonEncode({'token': token, 'expiresAt': '2026-10-11T10:00:00Z'}),
      200,
    );
  });
}

AuthController _auth({
  FakeCredentialStore? credentials,
  FakeServerStore? store,
  MockClient? client,
}) => AuthController(
  api: AuthApi(client: client ?? _authClient()),
  credentials: credentials ?? FakeCredentialStore(),
  store: store ?? FakeServerStore(),
);

Widget _app(AuthController auth) => MaterialShadcnApp(
  theme: proculLightTheme,
  darkTheme: proculDarkTheme,
  themeMode: ThemeMode.light,
  home: ConnectScreen(auth: auth),
);

Future<void> _pump(WidgetTester tester, AuthController auth) async {
  await tester.binding.setSurfaceSize(const Size(700, 900));
  addTearDown(() => tester.binding.setSurfaceSize(null));
  await tester.pumpWidget(_app(auth));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('renders the form and prefills the URL from the dart-define', (
    tester,
  ) async {
    await _pump(tester, _auth());

    expect(find.text('Procul'), findsOneWidget);
    expect(find.text('Connect to your server'), findsOneWidget);
    // Name, Base URL, Password.
    expect(find.byType(TextField), findsNWidgets(3));
    expect(
      find.widgetWithText(TextField, 'http://localhost:5010'),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('a successful connect adds the server and signs in', (
    tester,
  ) async {
    final auth = _auth();
    await _pump(tester, auth);

    await tester.enterText(find.byType(TextField).at(1), 'http://a.test');
    await tester.enterText(find.byType(TextField).at(2), 'pw');
    await tester.tap(find.text('Connect'));
    await tester.pumpAndSettle();

    expect(auth.active, isNotNull);
    expect(auth.profiles.single.baseUrl, 'http://a.test');
    expect(tester.takeException(), isNull);
  });

  testWidgets('a wrong password shows an inline error and stays put', (
    tester,
  ) async {
    final auth = _auth(client: _authClient(password: 'right'));
    await _pump(tester, auth);

    await tester.enterText(find.byType(TextField).at(1), 'http://a.test');
    await tester.enterText(find.byType(TextField).at(2), 'wrong');
    await tester.tap(find.text('Connect'));
    await tester.pumpAndSettle();

    expect(find.text('Incorrect password.'), findsOneWidget);
    expect(auth.active, isNull);
  });

  testWidgets('a bad URL is rejected before any request', (tester) async {
    final auth = _auth();
    await _pump(tester, auth);

    await tester.enterText(find.byType(TextField).at(1), 'ftp://nope');
    await tester.enterText(find.byType(TextField).at(2), 'pw');
    await tester.tap(find.text('Connect'));
    await tester.pumpAndSettle();

    expect(find.text('Enter a valid http(s) server URL.'), findsOneWidget);
    expect(auth.profiles, isEmpty);
  });

  testWidgets('warns about plain HTTP to a non-localhost host', (tester) async {
    await _pump(tester, _auth());

    await tester.enterText(
      find.byType(TextField).at(1),
      'http://chat.example.com',
    );
    await tester.pumpAndSettle();

    expect(find.textContaining('plain HTTP'), findsOneWidget);

    await tester.enterText(
      find.byType(TextField).at(1),
      'http://localhost:1234',
    );
    await tester.pumpAndSettle();

    expect(find.textContaining('plain HTTP'), findsNothing);
  });

  testWidgets('lists saved servers and signs in on tap when a token exists', (
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

    await _pump(tester, auth);

    expect(find.text('Saved servers'), findsOneWidget);
    expect(find.text('Home'), findsOneWidget);

    await tester.tap(find.text('Home'));
    await tester.pumpAndSettle();

    expect(auth.active, isNotNull);
    expect(auth.active!.token, 'stored');
  });

  testWidgets('selecting a saved server without a token prefills the form', (
    tester,
  ) async {
    const profile = ServerProfile(
      id: 'p1',
      name: 'Home',
      baseUrl: 'http://a.test',
    );
    final store = FakeServerStore(profiles: [profile], activeId: 'p1');
    final auth = _auth(store: store);
    await auth.init();

    await _pump(tester, auth);

    await tester.tap(find.text('Home'));
    await tester.pumpAndSettle();

    expect(auth.active, isNull);
    expect(find.widgetWithText(TextField, 'http://a.test'), findsOneWidget);
  });
}
