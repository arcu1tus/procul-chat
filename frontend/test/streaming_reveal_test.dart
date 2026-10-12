import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:gpt_markdown/gpt_markdown.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:procul_chat_flutter/src/app_theme.dart';
import 'package:procul_chat_flutter/src/chat_api.dart';
import 'package:procul_chat_flutter/src/chat_controller.dart';
import 'package:procul_chat_flutter/src/chat_screen.dart';
import 'package:shadcn_flutter/shadcn_flutter.dart';
import 'package:shadcn_flutter_material/shadcn_flutter_material.dart';

import 'support/fake_conversation_store.dart';

/// Builds the app with an optional reduced-motion override.
Widget _app(ChatController chat, {bool disableAnimations = false}) =>
    MaterialShadcnApp(
      theme: proculLightTheme,
      darkTheme: proculDarkTheme,
      themeMode: ThemeMode.light,
      builder: (context, child) {
        final media = MediaQuery.of(context);
        return MediaQuery(
          data: media.copyWith(disableAnimations: disableAnimations),
          child: child ?? const SizedBox.shrink(),
        );
      },
      home: ChatScreen(chat: chat),
    );

void main() {
  testWidgets('the reveal advances, then settles when done', (tester) async {
    await tester.binding.setSurfaceSize(const Size(1000, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    final stream = StreamController<List<int>>();
    addTearDown(() => stream.isClosed ? null : stream.close());
    final client = MockClient.streaming((request, body) async {
      if (request.method == 'GET') {
        return http.StreamedResponse(
          Stream.value(utf8.encode('{"conversations":[]}')),
          200,
        );
      }
      return http.StreamedResponse(
        stream.stream,
        200,
        headers: {'content-type': 'text/event-stream'},
      );
    });
    final chat = ChatController(
      api: ChatApi(baseUrl: 'http://test', token: 'tok', client: client),
      store: FakeConversationStore(),
    );

    await tester.pumpWidget(_app(chat));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'Hi');
    await tester.testTextInput.receiveAction(TextInputAction.send);
    await tester.pump();

    stream.add(
      utf8.encode(
        'data: {"value":{"conversation":{"id":"c1","title":"t"},'
        '"type":"created"}}\n\n',
      ),
    );
    await tester.pump();
    const reply = 'Hello world, this is a reply.';
    stream.add(
      utf8.encode('data: {"value":{"content":"$reply","type":"token"}}\n\n'),
    );
    await tester.pump();

    // While streaming the newest text is under a bloom and a caret trails it.
    expect(find.byKey(const Key('streaming-bloom')), findsOneWidget);
    expect(find.byKey(const Key('streaming-caret')), findsOneWidget);

    // The reveal has not yet caught up to the full reply.
    final partial = tester.widget<GptMarkdown>(find.byType(GptMarkdown)).data;
    expect(partial.length, lessThan(reply.length));

    // Given time, the pacer reveals the whole reply.
    await tester.pump(const Duration(milliseconds: 800));
    final full = tester.widget<GptMarkdown>(find.byType(GptMarkdown)).data;
    expect(full, reply);

    // Completion removes the bloom and caret.
    stream.add(utf8.encode('data: {"value":{"type":"done"}}\n\n'));
    await tester.pump();
    await stream.close();
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('streaming-bloom')), findsNothing);
    expect(find.byKey(const Key('streaming-caret')), findsNothing);
    expect(tester.widget<GptMarkdown>(find.byType(GptMarkdown)).data, reply);
    expect(tester.takeException(), isNull);
  });

  testWidgets('the reveal is inert under reduced motion', (tester) async {
    await tester.binding.setSurfaceSize(const Size(1000, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    final stream = StreamController<List<int>>();
    addTearDown(() => stream.isClosed ? null : stream.close());
    final client = MockClient.streaming((request, body) async {
      if (request.method == 'GET') {
        return http.StreamedResponse(
          Stream.value(utf8.encode('{"conversations":[]}')),
          200,
        );
      }
      return http.StreamedResponse(
        stream.stream,
        200,
        headers: {'content-type': 'text/event-stream'},
      );
    });
    final chat = ChatController(
      api: ChatApi(baseUrl: 'http://test', token: 'tok', client: client),
      store: FakeConversationStore(),
    );

    await tester.pumpWidget(_app(chat, disableAnimations: true));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'Hi');
    await tester.testTextInput.receiveAction(TextInputAction.send);
    await tester.pump();

    stream.add(
      utf8.encode(
        'data: {"value":{"conversation":{"id":"c1","title":"t"},'
        '"type":"created"}}\n\n',
      ),
    );
    await tester.pump();
    const reply = 'Hello world';
    stream.add(
      utf8.encode('data: {"value":{"content":"$reply","type":"token"}}\n\n'),
    );
    await tester.pump();

    // No bloom, no caret, and the full text appears at once.
    expect(find.byKey(const Key('streaming-bloom')), findsNothing);
    expect(find.byKey(const Key('streaming-caret')), findsNothing);
    expect(tester.widget<GptMarkdown>(find.byType(GptMarkdown)).data, reply);
    expect(tester.takeException(), isNull);
  });
}
