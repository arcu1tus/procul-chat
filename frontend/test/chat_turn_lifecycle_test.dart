import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:procul_chat_flutter/src/chat_api.dart';
import 'package:procul_chat_flutter/src/chat_controller.dart';

import 'support/fake_conversation_store.dart';

String _event(Map<String, Object?> value) =>
    'data: ${jsonEncode({'value': value})}\n\n';

Future<void> _until(ChatController chat, bool Function() predicate) {
  if (predicate()) return Future.value();
  final complete = Completer<void>();
  void listener() {
    if (!predicate()) return;
    chat.removeListener(listener);
    complete.complete();
  }

  chat.addListener(listener);
  return complete.future;
}

ChatController _chat(MockClient client) => ChatController(
  api: ChatApi(baseUrl: 'http://test', token: 'tok', client: client),
  store: FakeConversationStore(),
);

void main() {
  test(
    'a delayed title and old stream close cannot end a newer turn',
    () async {
      final first = StreamController<List<int>>();
      final second = StreamController<List<int>>();
      final chat = _chat(
        MockClient.streaming((request, _) async {
          return http.StreamedResponse(
            request.url.path == '/v1/conversations/'
                ? first.stream
                : second.stream,
            200,
          );
        }),
      );
      addTearDown(chat.dispose);
      final initial = chat.send('first');
      first.add(
        utf8.encode(
          _event({
                'type': 'created',
                'conversation': {'id': 'c1', 'title': 'first'},
              }) +
              _event({'type': 'token', 'content': 'one'}) +
              _event({'type': 'done', 'revision': 1}),
        ),
      );
      await _until(chat, () => !chat.isStreaming);
      final next = chat.send('second');
      expect(chat.isStreaming, isTrue);
      first.add(
        utf8.encode(
          _event({
            'type': 'title',
            'conversationId': 'c1',
            'title': 'Generated title',
          }),
        ),
      );
      await first.close();
      await initial;
      expect(chat.activeConversation!.title, 'Generated title');
      expect(chat.isStreaming, isTrue);
      expect(chat.activeConversation!.revision, 1);
      second.add(
        utf8.encode(
          _event({'type': 'token', 'content': 'two'}) +
              _event({'type': 'done', 'revision': 2}),
        ),
      );
      await second.close();
      await next;
      expect(chat.messages.map((m) => m.text), [
        'first',
        'one',
        'second',
        'two',
      ]);
      expect(chat.activeConversation!.revision, 2);
      expect(chat.isStreaming, isFalse);
    },
  );

  test(
    'switching to a fresh chat ignores an old reply and its revision',
    () async {
      final stream = StreamController<List<int>>();
      final chat = _chat(
        MockClient.streaming(
          (_, _) async => http.StreamedResponse(stream.stream, 200),
        ),
      );
      addTearDown(chat.dispose);
      final sending = chat.send('first');
      stream.add(
        utf8.encode(
          _event({
            'type': 'created',
            'conversation': {'id': 'c1', 'title': 'first'},
          }),
        ),
      );
      await _until(chat, () => chat.hasConversation);
      await chat.newChat();
      stream.add(
        utf8.encode(
          _event({'type': 'token', 'content': 'stale'}) +
              _event({'type': 'usage', 'totalTokens': 50}) +
              _event({'type': 'done', 'revision': 2}),
        ),
      );
      await stream.close();
      await sending;
      expect(chat.messages, isEmpty);
      expect(chat.hasConversation, isFalse);
      expect(chat.activeUsage.totalTokens, 0);
      expect(chat.isStreaming, isFalse);
    },
  );

  test(
    'generated images join the reply and reconcile with persisted history',
    () async {
      final chat = _chat(
        MockClient((request) async {
          if (request.method == 'POST') {
            return http.Response(
              _event({
                    'type': 'created',
                    'conversation': {'id': 'c1', 'title': 'image'},
                  }) +
                  _event({
                    'type': 'image',
                    'attachmentId': 'img',
                    'fileName': 'cat.png',
                    'contentType': 'image/png',
                  }) +
                  _event({'type': 'done', 'revision': 1}),
              200,
            );
          }
          return http.Response(
            jsonEncode({
              'messages': [
                {
                  'id': 'a1',
                  'text': '',
                  'messageRole': 2,
                  'attachments': [
                    {
                      'id': 'img',
                      'fileName': 'cat.png',
                      'contentType': 'image/png',
                      'sizeBytes': 42,
                    },
                  ],
                },
                {'id': 'u1', 'text': 'draw a cat', 'messageRole': 1},
              ],
            }),
            200,
          );
        }),
      );
      addTearDown(chat.dispose);
      await chat.send('draw a cat');
      final assistant = chat.messages.last;
      expect(assistant.text, isEmpty);
      expect(assistant.attachments.single.id, 'img');
      expect(assistant.attachments.single.isImage, isTrue);
      await chat.syncActiveConversation();
      expect(chat.messages, hasLength(2));
      expect(chat.messages.last, same(assistant));
      expect(assistant.id, 'a1');
    },
  );

  for (final failure in ['conflict', 'truncated', 'sse error']) {
    test(
      '$failure refreshes the revision so the next send can succeed',
      () async {
        var revision = 1;
        var sends = 0;
        final chat = _chat(
          MockClient((request) async {
            if (request.url.path == '/v1/conversations') {
              return http.Response(
                jsonEncode({
                  'conversations': [
                    {'id': 'c1', 'title': 'Chat', 'revision': revision},
                  ],
                }),
                200,
              );
            }
            if (request.method == 'POST') {
              sends++;
              final body = jsonDecode(request.body) as Map;
              expect(body['expectedRevision'], revision);
              revision++;
              if (sends == 1) {
                return switch (failure) {
                  'conflict' => http.Response('changed', 409),
                  'truncated' => http.Response(
                    _event({'type': 'token', 'content': 'partial'}),
                    200,
                  ),
                  _ => http.Response(
                    _event({'type': 'token', 'content': 'partial'}) +
                        _event({'type': 'error', 'error': 'model failed'}),
                    200,
                  ),
                };
              }
              return http.Response(
                _event({'type': 'token', 'content': 'ok'}) +
                    _event({'type': 'done', 'revision': revision}),
                200,
              );
            }
            return http.Response(
              jsonEncode({
                'messages': [
                  {'id': 'u1', 'text': 'original', 'messageRole': 1},
                ],
              }),
              200,
            );
          }),
        );
        addTearDown(chat.dispose);
        await chat.init();
        await chat.selectConversation('c1');
        await chat.send('first');
        expect(chat.error, isNotNull);
        expect(chat.activeConversation!.revision, 2);
        if (failure == 'sse error') expect(chat.messages.last.text, 'partial');
        await chat.send('retry');
        expect(sends, 2);
        expect(chat.messages.last.text, 'ok');
        expect(chat.activeConversation!.revision, 3);
        expect(chat.error, isNull);
      },
    );
  }

  test('disposing during a stream suppresses late updates', () async {
    final stream = StreamController<List<int>>();
    final chat = _chat(
      MockClient.streaming(
        (_, _) async => http.StreamedResponse(stream.stream, 200),
      ),
    );
    final sending = chat.send('hello');
    chat.dispose();
    stream.add(utf8.encode(_event({'type': 'token', 'content': 'late'})));
    await stream.close();
    await sending;
    expect(chat.messages.last.text, isEmpty);
  });
}
