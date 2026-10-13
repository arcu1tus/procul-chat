import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:gpt_markdown/gpt_markdown.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:procul_chat_flutter/src/app_theme.dart';
import 'package:procul_chat_flutter/src/chat_api.dart';
import 'package:procul_chat_flutter/src/chat_controller.dart';
import 'package:procul_chat_flutter/src/chat_screen.dart';
import 'package:procul_chat_flutter/src/widgets/composer.dart';
import 'package:shadcn_flutter/shadcn_flutter.dart';
import 'package:shadcn_flutter_material/shadcn_flutter_material.dart';

import 'support/fake_conversation_store.dart';

const _conversation = {
  'id': 'c1',
  'title': 'Chat',
  'createdAt': '2026-10-11T10:00:00Z',
  'updatedAt': '2026-10-11T10:00:00Z',
};

/// History newest-first (as the backend returns it), so the buffer becomes
/// `[user, assistant]`.
const _messages = [
  {
    'id': 'm2',
    'conversationId': 'c1',
    'text': 'Hi! How can I help?',
    'messageRole': 2,
    'createdAt': '2026-10-11T10:01:00Z',
    'model': 'local/llama',
    'usage': {
      'inputTokens': 10,
      'outputTokens': 5,
      'cachedInputTokens': 2,
      'totalTokens': 17,
    },
  },
  {
    'id': 'm1',
    'conversationId': 'c1',
    'text': 'Hello there',
    'messageRole': 1,
    'createdAt': '2026-10-11T10:00:00Z',
  },
];

MockClient _client() => MockClient((request) async {
  final path = request.url.path;
  if (path == '/v1/conversations' && request.method == 'GET') {
    return http.Response(
      jsonEncode({
        'conversations': [_conversation],
      }),
      200,
    );
  }
  if (path == '/v1/conversations/c1/messages') {
    return http.Response(jsonEncode({'messages': _messages}), 200);
  }
  if (path.startsWith('/v1/usage/')) return http.Response('{}', 200);
  return http.Response('{}', 200);
});

Widget _app(ChatController chat) => MaterialShadcnApp(
  theme: proculLightTheme,
  darkTheme: proculDarkTheme,
  themeMode: ThemeMode.light,
  home: ChatScreen(chat: chat),
);

Future<ChatController> _loaded(WidgetTester tester) async {
  final chat = ChatController(
    api: ChatApi(baseUrl: 'http://test', token: 'tok', client: _client()),
    store: FakeConversationStore('c1'),
  );
  await chat.init();
  await tester.pumpWidget(_app(chat));
  await tester.pumpAndSettle();
  return chat;
}

/// Whether any [Container] ancestor of [descendant] paints a border.
bool _hasBorderedAncestor(WidgetTester tester, Finder descendant) {
  final ancestors = find.ancestor(
    of: descendant,
    matching: find.byType(Container),
  );
  for (final element in ancestors.evaluate()) {
    final decoration = (element.widget as Container).decoration;
    if (decoration is BoxDecoration && decoration.border != null) return true;
  }
  return false;
}

void main() {
  testWidgets('the user bubble has no avatar and is right-aligned', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1000, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await _loaded(tester);

    expect(find.text('Hello there'), findsOneWidget);
    // No blank user avatar any more.
    expect(find.byIcon(LucideIcons.user), findsNothing);

    // Right-aligned: the bubble's right edge sits past the middle of the pane.
    final rect = tester.getRect(find.text('Hello there'));
    expect(rect.right, greaterThan(500));
    expect(tester.takeException(), isNull);
  });

  testWidgets('the assistant reply has no bubble border and keeps its avatar', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1000, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await _loaded(tester);

    // The reply renders directly on the background — no bordered container.
    expect(_hasBorderedAncestor(tester, find.byType(GptMarkdown)), isFalse);

    // The assistant keeps its tappable brand mark.
    expect(find.byKey(const Key('response-details')), findsOneWidget);
  });

  testWidgets('the assistant avatar opens model + token details', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1000, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await _loaded(tester);

    await tester.tap(find.byKey(const Key('response-details')).first);
    await tester.pumpAndSettle();

    expect(find.text('Model'), findsOneWidget);
    expect(find.text('local/llama'), findsOneWidget);
    expect(find.text('Input'), findsOneWidget);
    expect(find.text('Output'), findsOneWidget);
    expect(find.text('Cached'), findsOneWidget);
    expect(find.text('Total'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('the composer builds as a capsule with a circular send button', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1000, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await _loaded(tester);

    expect(find.byType(Composer), findsOneWidget);
    expect(find.byType(TextField), findsOneWidget);

    // The capsule is a rounded surface with a border.
    final capsule = find.descendant(
      of: find.byType(Composer),
      matching: find.byWidgetPredicate(
        (widget) =>
            widget is AnimatedContainer &&
            widget.decoration is BoxDecoration &&
            (widget.decoration! as BoxDecoration).borderRadius ==
                BorderRadius.circular(24),
      ),
    );
    expect(capsule, findsOneWidget);

    // The send control is a circular primary button.
    final send = tester.widget<PrimaryButton>(find.byType(PrimaryButton));
    expect(send.shape, ButtonShape.circle);
    expect(send.onPressed, isNull);
    expect(tester.takeException(), isNull);
  });

  testWidgets('the capsule shows an animated focus ring', (tester) async {
    await tester.binding.setSurfaceSize(const Size(1000, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await _loaded(tester);

    // Focus animates the capsule's border (1 → 1.5 px).
    final capsuleFinder = find.descendant(
      of: find.byType(Composer),
      matching: find.byWidgetPredicate(
        (widget) =>
            widget is AnimatedContainer &&
            widget.decoration is BoxDecoration &&
            (widget.decoration! as BoxDecoration).borderRadius ==
                BorderRadius.circular(24),
      ),
    );
    double borderWidth() {
      final decoration =
          tester.widget<AnimatedContainer>(capsuleFinder).decoration
              as BoxDecoration;
      return (decoration.border! as Border).top.width;
    }

    expect(borderWidth(), 1);
    await tester.tap(find.byType(TextField));
    await tester.pumpAndSettle();
    expect(borderWidth(), 1.5);
    expect(tester.takeException(), isNull);
  });
}
