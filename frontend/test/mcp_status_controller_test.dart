import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:procul_chat_flutter/src/chat_api.dart';
import 'package:procul_chat_flutter/src/mcp_status_controller.dart';

const _serversJson = {
  'servers': [
    {
      'name': 'github',
      'type': 'http',
      'url': 'https://api.githubcopilot.com/mcp/',
      'connected': true,
      'toolCount': 2,
      'tools': ['search_repositories', 'list_commits'],
      'lastError': null,
      'lastConnectedAt': '2026-10-11T12:00:00Z',
    },
    {
      'name': 'legacy',
      'type': 'sse',
      'url': 'https://example.com/sse',
      'connected': false,
      'toolCount': 0,
      'tools': <String>[],
      'lastError': 'connection refused',
      'lastConnectedAt': null,
    },
  ],
};

ChatApi _api(MockClient client) =>
    ChatApi(baseUrl: 'http://test', token: 'tok', client: client);

void main() {
  test('a stale refresh failure cannot clear a newer loading state', () async {
    final first = Completer<http.Response>();
    final second = Completer<http.Response>();
    var requests = 0;
    final controller = McpStatusController(
      api: _api(
        MockClient((_) {
          return requests++ == 0 ? first.future : second.future;
        }),
      ),
    );
    addTearDown(controller.dispose);
    final loading = controller.load();
    final refreshing = controller.refresh();
    first.complete(http.Response('old request failed', 500));
    await loading;
    expect(controller.isLoading, isTrue);
    expect(controller.error, isNull);
    second.complete(http.Response(jsonEncode({'servers': []}), 200));
    await refreshing;
    expect(controller.error, isNull);
    expect(controller.isLoading, isFalse);
  });

  test('disposing during load ignores the late response', () async {
    final response = Completer<http.Response>();
    final controller = McpStatusController(
      api: _api(MockClient((_) => response.future)),
    );
    final loading = controller.load();
    controller.dispose();
    response.complete(http.Response(jsonEncode({'servers': []}), 200));
    await loading;
    expect(controller.servers, isEmpty);
  });

  test(
    'fetchMcpServers parses the payload and sends the bearer token',
    () async {
      late http.BaseRequest seen;
      final api = _api(
        MockClient((request) async {
          seen = request;
          return http.Response(jsonEncode(_serversJson), 200);
        }),
      );

      final servers = await api.fetchMcpServers();

      expect(seen.url.path, '/v1/mcp/servers');
      expect(seen.headers['Authorization'], 'Bearer tok');
      expect(servers, hasLength(2));
      expect(servers.first.name, 'github');
      expect(servers.first.connected, isTrue);
      expect(servers.first.toolCount, 2);
      expect(servers.first.tools, ['search_repositories', 'list_commits']);
      expect(servers[1].connected, isFalse);
      expect(servers[1].lastError, 'connection refused');
    },
  );

  test('the controller loads servers and clears loading', () async {
    final controller = McpStatusController(
      api: _api(
        MockClient((_) async => http.Response(jsonEncode(_serversJson), 200)),
      ),
    );

    expect(controller.isLoading, isFalse);
    await controller.load();

    expect(controller.isLoading, isFalse);
    expect(controller.error, isNull);
    expect(controller.servers, hasLength(2));
  });

  test('refresh surfaces a failure as a user-facing error', () async {
    final controller = McpStatusController(
      api: _api(MockClient((_) async => http.Response('boom', 500))),
    );

    await controller.refresh();

    expect(controller.servers, isEmpty);
    expect(controller.error, isNotNull);
    expect(controller.error, contains('Could not load tool servers'));
  });

  test('refresh recovers after a failure', () async {
    var fail = true;
    final controller = McpStatusController(
      api: _api(
        MockClient(
          (_) async => fail
              ? http.Response('boom', 500)
              : http.Response(jsonEncode(_serversJson), 200),
        ),
      ),
    );

    await controller.refresh();
    expect(controller.error, isNotNull);

    fail = false;
    await controller.refresh();
    expect(controller.error, isNull);
    expect(controller.servers, hasLength(2));
  });
}
