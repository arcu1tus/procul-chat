import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:procul_chat_flutter/src/chat_api.dart';
import 'package:procul_chat_flutter/src/usage_controller.dart';

const _summaryJson = {
  'lifetime': {
    'inputTokens': 100,
    'outputTokens': 50,
    'cachedInputTokens': 20,
    'totalTokens': 150,
    'turns': 2,
  },
  'days': [
    {
      'date': '2026-10-11',
      'inputTokens': 100,
      'outputTokens': 50,
      'cachedInputTokens': 20,
      'totalTokens': 150,
      'turns': 1,
    },
    {
      'date': '2026-10-10',
      'inputTokens': 0,
      'outputTokens': 0,
      'cachedInputTokens': 0,
      'totalTokens': 0,
      'turns': 0,
    },
  ],
  'models': [
    {
      'model': 'test/model',
      'inputTokens': 100,
      'outputTokens': 50,
      'cachedInputTokens': 20,
      'totalTokens': 150,
      'turns': 1,
    },
  ],
};

ChatApi _api(MockClient client) =>
    ChatApi(baseUrl: 'http://test', token: 'tok', client: client);

void main() {
  test(
    'fetchUsage parses the payload, sends the token, and passes days',
    () async {
      late http.BaseRequest seen;
      final api = _api(
        MockClient((request) async {
          seen = request;
          return http.Response(jsonEncode(_summaryJson), 200);
        }),
      );

      final summary = await api.fetchUsage(days: 7);

      expect(seen.url.path, '/v1/usage');
      expect(seen.url.queryParameters['days'], '7');
      expect(seen.headers['Authorization'], 'Bearer tok');
      expect(summary.lifetime.totalTokens, 150);
      expect(summary.lifetime.turns, 2);
      expect(summary.days, hasLength(2));
      expect(summary.models.single.model, 'test/model');
    },
  );

  test('the controller loads the summary and clears loading', () async {
    final controller = UsageController(
      api: _api(
        MockClient((_) async => http.Response(jsonEncode(_summaryJson), 200)),
      ),
    );

    expect(controller.isLoading, isFalse);
    expect(controller.summary, isNull);

    await controller.load();

    expect(controller.isLoading, isFalse);
    expect(controller.error, isNull);
    expect(controller.isEmpty, isFalse);
    expect(controller.lifetime.totalTokens, 150);
    expect(controller.days, hasLength(2));
    expect(controller.models, hasLength(1));
  });

  test('refresh surfaces a failure as a user-facing error', () async {
    final controller = UsageController(
      api: _api(MockClient((_) async => http.Response('boom', 500))),
    );

    await controller.refresh();

    expect(controller.summary, isNull);
    expect(controller.error, isNotNull);
    expect(controller.error, contains('Could not load usage'));
  });

  test('refresh recovers after a failure', () async {
    var fail = true;
    final controller = UsageController(
      api: _api(
        MockClient(
          (_) async => fail
              ? http.Response('boom', 500)
              : http.Response(jsonEncode(_summaryJson), 200),
        ),
      ),
    );

    await controller.refresh();
    expect(controller.error, isNotNull);

    fail = false;
    await controller.refresh();
    expect(controller.error, isNull);
    expect(controller.lifetime.totalTokens, 150);
  });

  test(
    'setRange refetches with the new window and is a no-op when unchanged',
    () async {
      var requests = 0;
      late String? lastDays;
      final controller = UsageController(
        api: _api(
          MockClient((request) async {
            requests++;
            lastDays = request.url.queryParameters['days'];
            return http.Response(jsonEncode(_summaryJson), 200);
          }),
        ),
      );

      await controller.load();
      expect(requests, 1);
      expect(lastDays, '30');

      await controller.setRange(7);
      expect(controller.selectedRange, 7);
      expect(requests, 2);
      expect(lastDays, '7');

      // Selecting the same range again does not refetch.
      await controller.setRange(7);
      expect(requests, 2);
    },
  );
}
