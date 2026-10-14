import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:procul_chat_flutter/src/chat_api.dart';
import 'package:procul_chat_flutter/src/chat_controller.dart';

import 'support/fake_conversation_store.dart';

const _sse =
    'data: {"value":{"conversation":{"id":"c1","title":"t"},'
    '"type":"created"}}\n\n'
    'data: {"value":{"message":"received","type":"acknowledge"}}\n\n'
    'data: {"value":{"callId":"call-1","name":"get_current_time",'
    '"arguments":"{\\"utcOffsetMinutes\\":120}","type":"toolCall"}}\n\n'
    'data: {"value":{"callId":"call-1","result":"2026-10-11T15:38:44+02:00",'
    '"error":null,"type":"toolResult"}}\n\n'
    'data: {"value":{"content":"It is 15:38","type":"token"}}\n\n'
    'data: {"value":{"type":"done"}}\n\n';

void main() {
  test('reasoning SSE is separate from the answer and null tool output completes', () async {
    final api = ChatApi(
      baseUrl: 'http://test',
      token: 'test',
      client: MockClient(
        (_) async => http.Response(
          'data: {"value":{"type":"reasoning","content":"visible thinking"}}\n\n'
          'data: {"value":{"type":"toolCall","callId":"c","name":"tool"}}\n\n'
          'data: {"value":{"type":"toolResult","callId":"c","result":null}}\n\n'
          'data: {"value":{"type":"token","content":"answer"}}\n\n'
          'data: {"value":{"type":"done"}}\n\n',
          200,
          headers: {'content-type': 'text/event-stream'},
        ),
      ),
    );
    final chat = ChatController(api: api, store: FakeConversationStore());
    addTearDown(chat.dispose);
    await chat.send('test');
    final response = chat.messages.last;
    expect(response.text, 'answer');
    expect(response.reasoning, 'visible thinking');
    expect(response.toolCalls.single.status, 'completed');
    expect(response.toolCalls.single.isPending, isFalse);
    expect(response.phase, 'done');
  });

  test('controller records tool call and result from the SSE stream', () async {
    final client = MockClient.streaming((request, body) async {
      return http.StreamedResponse(
        Stream.value(utf8.encode(_sse)),
        200,
        headers: {'content-type': 'text/event-stream'},
      );
    });
    final api = ChatApi(
      baseUrl: 'http://test',
      token: 'test-token',
      client: client,
    );
    final controller = ChatController(api: api, store: FakeConversationStore());

    await controller.send('what time is it?');

    final assistant = controller.messages.last;
    expect(assistant.toolCalls, hasLength(1));
    final call = assistant.toolCalls.single;
    expect(call.name, 'get_current_time');
    expect(call.arguments, '{"utcOffsetMinutes":120}');
    expect(call.result, '2026-10-11T15:38:44+02:00');
    expect(call.isPending, isFalse);
    expect(call.hasFailed, isFalse);
    expect(assistant.text, 'It is 15:38');
    expect(controller.isStreaming, isFalse);
    expect(controller.error, isNull);
  });
}
