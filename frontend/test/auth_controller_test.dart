import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:procul_chat_flutter/src/auth_api.dart';
import 'package:procul_chat_flutter/src/auth_controller.dart';
import 'package:procul_chat_flutter/src/server_profile.dart';

import 'support/fake_credential_store.dart';
import 'support/fake_server_store.dart';

/// A mock auth server: returns a token for [password], 401 otherwise.
MockClient _authClient({String password = 'pw', String token = 'tok-1'}) {
  return MockClient((request) async {
    if (request.url.path != '/v1/auth/session') {
      return http.Response('not found', 404);
    }
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

AuthController _controller({
  required FakeCredentialStore credentials,
  required FakeServerStore store,
  MockClient? client,
}) => AuthController(
  api: AuthApi(client: client ?? _authClient()),
  credentials: credentials,
  store: store,
);

void main() {
  test(
    'a delayed 401 for a replaced session cannot log out the newer token',
    () async {
      var issued = 0;
      final auth = _controller(
        credentials: FakeCredentialStore(),
        store: FakeServerStore(),
        client: MockClient(
          (_) async =>
              http.Response(jsonEncode({'token': 'token-${++issued}'}), 200),
        ),
      );
      addTearDown(auth.dispose);
      await auth.connect(baseUrl: 'https://example.test', password: 'pw');
      final old = auth.active!;
      await auth.connect(baseUrl: 'https://example.test', password: 'pw');
      await auth.invalidateSession(old);
      expect(auth.active!.token, 'token-2');
      final invalidating = auth.invalidateSession(auth.active!);
      expect(auth.active, isNull);
      await invalidating;
    },
  );

  test('connect saves a profile and the token, and authenticates', () async {
    final credentials = FakeCredentialStore();
    final store = FakeServerStore();
    final auth = _controller(credentials: credentials, store: store);

    final ok = await auth.connect(
      baseUrl: 'http://localhost:5010',
      password: 'pw',
    );

    expect(ok, isTrue);
    expect(auth.error, isNull);
    expect(auth.profiles, hasLength(1));
    expect(auth.profiles.single.name, 'localhost');
    expect(auth.profiles.single.baseUrl, 'http://localhost:5010');
    expect(auth.active, isNotNull);
    expect(auth.active!.token, 'tok-1');
    expect(credentials.tokens[auth.profiles.single.id], 'tok-1');
    expect(store.profiles, hasLength(1));
    expect(store.activeId, auth.profiles.single.id);
  });

  test(
    'connect trims a trailing slash and reuses an existing profile',
    () async {
      final credentials = FakeCredentialStore();
      final store = FakeServerStore();
      final auth = _controller(credentials: credentials, store: store);

      await auth.connect(baseUrl: 'http://a.test/', password: 'pw');
      await auth.connect(baseUrl: 'http://a.test', password: 'pw');

      expect(auth.profiles, hasLength(1));
      expect(auth.profiles.single.baseUrl, 'http://a.test');
    },
  );

  test('a wrong password fails and leaves the app unauthenticated', () async {
    final auth = _controller(
      credentials: FakeCredentialStore(),
      store: FakeServerStore(),
    );

    final ok = await auth.connect(baseUrl: 'http://a.test', password: 'wrong');

    expect(ok, isFalse);
    expect(auth.active, isNull);
    expect(auth.error, 'Incorrect password.');
    expect(auth.profiles, isEmpty);
  });

  test('an unreachable server surfaces an error', () async {
    final client = MockClient((_) async => throw Exception('boom'));
    final auth = _controller(
      credentials: FakeCredentialStore(),
      store: FakeServerStore(),
      client: client,
    );

    final ok = await auth.connect(baseUrl: 'http://a.test', password: 'pw');

    expect(ok, isFalse);
    expect(auth.error, contains('Could not reach the server'));
  });

  test('an invalid URL is rejected without any request', () async {
    var requested = false;
    final client = MockClient((_) async {
      requested = true;
      return http.Response('{}', 200);
    });
    final auth = _controller(
      credentials: FakeCredentialStore(),
      store: FakeServerStore(),
      client: client,
    );

    final ok = await auth.connect(baseUrl: 'not a url', password: 'pw');

    expect(ok, isFalse);
    expect(auth.error, contains('valid http(s) server URL'));
    expect(requested, isFalse);
    expect(auth.profiles, isEmpty);
  });

  test('the name defaults to the URL host but an explicit name wins', () async {
    final auth = _controller(
      credentials: FakeCredentialStore(),
      store: FakeServerStore(),
    );

    await auth.connect(baseUrl: 'https://chat.example.com', password: 'pw');
    expect(auth.profiles.single.name, 'chat.example.com');

    await auth.connect(
      baseUrl: 'https://other.example.com',
      password: 'pw',
      name: '  Home  ',
    );
    expect(auth.profiles.last.name, 'Home');
  });

  test('logout clears only the active token and keeps the profile', () async {
    final credentials = FakeCredentialStore();
    final store = FakeServerStore();
    final auth = _controller(credentials: credentials, store: store);

    await auth.connect(baseUrl: 'http://a.test', password: 'pw');
    final a = auth.profiles.single;
    await auth.connect(baseUrl: 'http://b.test', password: 'pw');
    final b = auth.profiles.last;

    await auth.logout();

    expect(auth.active, isNull);
    expect(auth.activeId, b.id, reason: 'the URL is preserved');
    expect(credentials.tokens.containsKey(b.id), isFalse);
    expect(credentials.tokens[a.id], 'tok-1');
    expect(auth.profiles, hasLength(2));
  });

  test('switchTo uses the stored token', () async {
    final credentials = FakeCredentialStore();
    final auth = _controller(
      credentials: credentials,
      store: FakeServerStore(),
    );

    await auth.connect(baseUrl: 'http://a.test', password: 'pw');
    final a = auth.profiles.single;
    await auth.connect(baseUrl: 'http://b.test', password: 'pw');

    final ok = await auth.switchTo(a.id);

    expect(ok, isTrue);
    expect(auth.active!.profile.id, a.id);
    expect(auth.active!.token, 'tok-1');
  });

  test(
    'switchTo without a stored token leaves the app unauthenticated',
    () async {
      final profile = const ServerProfile(
        id: 'p1',
        name: 'A',
        baseUrl: 'http://a.test',
      );
      final auth = _controller(
        credentials: FakeCredentialStore(),
        store: FakeServerStore(profiles: [profile]),
      );
      await auth.init();

      final ok = await auth.switchTo('p1');

      expect(ok, isFalse);
      expect(auth.activeProfile?.id, 'p1');
      expect(auth.active, isNull);
    },
  );

  test('removing a non-active profile keeps the active session', () async {
    final credentials = FakeCredentialStore();
    final store = FakeServerStore();
    final auth = _controller(credentials: credentials, store: store);

    await auth.connect(baseUrl: 'http://a.test', password: 'pw');
    final a = auth.profiles.single;
    await auth.connect(baseUrl: 'http://b.test', password: 'pw');
    final b = auth.profiles.last;

    await auth.removeProfile(a.id);

    expect(auth.profiles.single.id, b.id);
    expect(auth.active!.profile.id, b.id);
    expect(credentials.tokens.containsKey(a.id), isFalse);
    expect(store.profiles, hasLength(1));
  });

  test('removing the active profile logs out', () async {
    final credentials = FakeCredentialStore();
    final store = FakeServerStore();
    final auth = _controller(credentials: credentials, store: store);

    await auth.connect(baseUrl: 'http://a.test', password: 'pw');
    final a = auth.profiles.single;

    await auth.removeProfile(a.id);

    expect(auth.active, isNull);
    expect(auth.activeId, isNull);
    expect(auth.profiles, isEmpty);
    expect(credentials.tokens, isEmpty);
    expect(store.profiles, isEmpty);
    expect(store.activeId, isNull);
  });

  test('renameProfile updates the persisted name', () async {
    final store = FakeServerStore();
    final auth = _controller(credentials: FakeCredentialStore(), store: store);

    await auth.connect(baseUrl: 'http://a.test', password: 'pw');
    final id = auth.profiles.single.id;

    await auth.renameProfile(id, 'Renamed');

    expect(auth.profiles.single.name, 'Renamed');
    expect(store.profiles.single.name, 'Renamed');
  });

  test(
    'profiles and the active session round-trip across controllers',
    () async {
      final credentials = FakeCredentialStore();
      final store = FakeServerStore();

      final first = _controller(credentials: credentials, store: store);
      await first.connect(baseUrl: 'http://a.test', password: 'pw');
      final id = first.profiles.single.id;

      final second = _controller(credentials: credentials, store: store);
      await second.init();

      expect(second.active, isNotNull);
      expect(second.active!.profile.id, id);
      expect(second.active!.token, 'tok-1');
    },
  );

  test(
    'init without a stored token keeps the profile but stays signed out',
    () async {
      final profile = const ServerProfile(
        id: 'p1',
        name: 'A',
        baseUrl: 'http://a.test',
      );
      final auth = _controller(
        credentials: FakeCredentialStore(),
        store: FakeServerStore(profiles: [profile], activeId: 'p1'),
      );

      await auth.init();

      expect(auth.activeProfile?.id, 'p1');
      expect(auth.active, isNull);
    },
  );
}
