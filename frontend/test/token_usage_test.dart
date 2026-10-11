import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:procul_chat_flutter/src/chat_api.dart';
import 'package:procul_chat_flutter/src/chat_stream_event.dart';
import 'package:procul_chat_flutter/src/models.dart';

void main() {
  group('formatTokenCount', () {
    test('renders small counts verbatim', () {
      expect(formatTokenCount(0), '0');
      expect(formatTokenCount(7), '7');
      expect(formatTokenCount(999), '999');
    });

    test('renders thousands with one decimal', () {
      expect(formatTokenCount(1000), '1.0k');
      expect(formatTokenCount(12400), '12.4k');
      expect(formatTokenCount(999999), '1000.0k');
    });

    test('renders millions with one decimal', () {
      expect(formatTokenCount(1200000), '1.2M');
      expect(formatTokenCount(2500000), '2.5M');
    });
  });

  test(
    'TokenUsage.fromJson reads the camelCase shape and defaults to zero',
    () {
      final usage = TokenUsage.fromJson(const {
        'inputTokens': 10,
        'outputTokens': 5,
        'cachedInputTokens': 2,
        'totalTokens': 17,
        'turns': 4,
      });

      expect(usage.inputTokens, 10);
      expect(usage.outputTokens, 5);
      expect(usage.cachedInputTokens, 2);
      expect(usage.totalTokens, 17);
      expect(usage.turns, 4);
      expect(usage.hasTokens, isTrue);

      final empty = TokenUsage.fromJson(const {});
      expect(empty.totalTokens, 0);
      expect(empty.hasTokens, isFalse);
    },
  );

  test('TokenUsage + sums each field', () {
    const a = TokenUsage(
      inputTokens: 1,
      outputTokens: 2,
      cachedInputTokens: 3,
      totalTokens: 4,
      turns: 5,
    );
    const b = TokenUsage(
      inputTokens: 10,
      outputTokens: 20,
      cachedInputTokens: 30,
      totalTokens: 40,
      turns: 5,
    );

    final sum = a + b;

    expect(sum.inputTokens, 11);
    expect(sum.outputTokens, 22);
    expect(sum.cachedInputTokens, 33);
    expect(sum.totalTokens, 44);
    expect(sum.turns, 10);
  });

  test('decodes a usage SSE event', () async {
    const sse =
        'data: {"value":{"inputTokens":10,"outputTokens":5,'
        '"cachedInputTokens":2,"totalTokens":17,"type":"usage"}}\n\n';
    final client = MockClient.streaming(
      (request, body) async => http.StreamedResponse(
        Stream.value(utf8.encode(sse)),
        200,
        headers: {'content-type': 'text/event-stream'},
      ),
    );
    final api = ChatApi(baseUrl: 'http://test', token: 'tok', client: client);

    final events = await api.sendMessage('c1', 'hi').toList();

    final event = events.single;
    expect(event, isA<UsageEvent>());
    final usage = (event as UsageEvent).usage;
    expect(usage.inputTokens, 10);
    expect(usage.outputTokens, 5);
    expect(usage.cachedInputTokens, 2);
    expect(usage.totalTokens, 17);
  });
}
