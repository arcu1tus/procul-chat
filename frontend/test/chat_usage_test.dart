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

const _sse =
    'data: {"value":{"conversation":{"id":"c1","title":"Greeting",'
    '"createdAt":"2026-10-11T10:00:00Z","updatedAt":"2026-10-11T10:00:00Z"},'
    '"type":"created"}}\n\n'
    'data: {"value":{"content":"Hello","type":"token"}}\n\n'
    'data: {"value":{"inputTokens":10,"outputTokens":5,'
    '"cachedInputTokens":2,"totalTokens":17,"type":"usage"}}\n\n'
    'data: {"value":{"type":"done"}}\n\n';

Widget _app(ChatController chat) => MaterialShadcnApp(
  theme: proculLightTheme,
  darkTheme: proculDarkTheme,
  themeMode: ThemeMode.light,
  home: ChatScreen(chat: chat),
);

void main() {
  testWidgets('the app-bar chip appears and shows the turn usage', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1000, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    final client = MockClient.streaming((request, body) async {
      if (request.method == 'GET') {
        return http.StreamedResponse(
          Stream.value(utf8.encode('{"conversations":[]}')),
          200,
        );
      }
      return http.StreamedResponse(
        Stream.value(utf8.encode(_sse)),
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

    expect(find.textContaining('tokens'), findsNothing);

    await tester.enterText(find.byType(TextField), 'Hi');
    await tester.testTextInput.receiveAction(TextInputAction.send);
    await tester.pumpAndSettle();

    expect(find.text('17 tokens'), findsOneWidget);

    // Tapping the chip reveals the input / output / cached / total breakdown.
    await tester.tap(find.text('17 tokens'));
    await tester.pumpAndSettle();
    expect(find.text('Input'), findsOneWidget);
    expect(find.text('Output'), findsOneWidget);
    expect(find.text('Cached'), findsOneWidget);
    expect(find.text('Total'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('assistant text shimmers while streaming and settles when done', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1000, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    final stream = StreamController<List<int>>();
    // Guard against a second close: awaiting `close()` on an already-closed
    // controller never completes under flutter_test's fake async.
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
    stream.add(
      utf8.encode('data: {"value":{"content":"Hello","type":"token"}}\n\n'),
    );
    await tester.pump();

    // While the reply streams, the assistant Markdown sits under a shimmer mask.
    expect(
      find.ancestor(
        of: find.byType(GptMarkdown),
        matching: find.byType(ShaderMask),
      ),
      findsOneWidget,
    );

    stream.add(utf8.encode('data: {"value":{"type":"done"}}\n\n'));
    await tester.pump();
    await stream.close();
    await tester.pumpAndSettle();

    // Once complete, the shimmer is gone.
    expect(
      find.ancestor(
        of: find.byType(GptMarkdown),
        matching: find.byType(ShaderMask),
      ),
      findsNothing,
    );
  });
}
