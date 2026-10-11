import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:procul_chat_flutter/src/chat_api.dart';

void main() {
  test('every request carries the bearer token', () async {
    final seen = <http.BaseRequest>[];
    final client = MockClient((request) async {
      seen.add(request);
      return http.Response('{"conversations":[]}', 200);
    });
    final api = ChatApi(
      baseUrl: 'http://test',
      token: 'secret',
      client: client,
    );

    await api.listConversations();

    expect(seen.single.headers['Authorization'], 'Bearer secret');
  });

  test(
    'a 401 throws UnauthorizedException and fires onUnauthorized once',
    () async {
      var unauthorized = 0;
      final client = MockClient((request) async => http.Response('nope', 401));
      final api = ChatApi(
        baseUrl: 'http://test',
        token: 'expired',
        client: client,
        onUnauthorized: () => unauthorized++,
      );

      await expectLater(
        api.listConversations(),
        throwsA(isA<UnauthorizedException>()),
      );

      expect(unauthorized, 1);
    },
  );

  test('a 401 on the SSE POST throws UnauthorizedException', () async {
    final client = MockClient((request) async => http.Response('nope', 401));
    final api = ChatApi(
      baseUrl: 'http://test',
      token: 'expired',
      client: client,
    );

    await expectLater(
      api.sendMessage('c1', 'hi').drain<void>(),
      throwsA(isA<UnauthorizedException>()),
    );
  });
}
