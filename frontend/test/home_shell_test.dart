import 'support/policy_chat_api.dart';

import 'dart:convert';

import 'package:flutter/services.dart' show LogicalKeyboardKey;
import 'package:flutter_test/flutter_test.dart';
import 'package:gpt_markdown/gpt_markdown.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:procul_chat_flutter/src/app_theme.dart';
import 'package:procul_chat_flutter/src/auth_api.dart';
import 'package:procul_chat_flutter/src/auth_controller.dart';
import 'package:procul_chat_flutter/src/chat_controller.dart';
import 'package:procul_chat_flutter/src/conversation_sidebar.dart';
import 'package:procul_chat_flutter/src/home_shell.dart';
import 'package:procul_chat_flutter/src/settings_controller.dart';
import 'package:procul_chat_flutter/src/settings_screen.dart';
import 'package:shadcn_flutter/shadcn_flutter.dart';
import 'package:shadcn_flutter_material/shadcn_flutter_material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/fake_conversation_store.dart';
import 'support/fake_credential_store.dart';
import 'support/fake_server_store.dart';
import 'support/model_fixtures.dart';

const _sse =
    'data: {"value":{"conversation":{"id":"c1","title":"Greeting",'
    '"createdAt":"2026-10-11T10:00:00Z","updatedAt":"2026-10-11T10:00:00Z"},'
    '"type":"created"}}\n\n'
    'data: {"value":{"content":"Hello **world**","type":"token"}}\n\n'
    'data: {"value":{"type":"done"}}\n\n';

AuthController _auth() => AuthController(
  api: AuthApi(client: MockClient((_) async => http.Response('{}', 200))),
  credentials: FakeCredentialStore(),
  store: FakeServerStore(),
);

Widget _app({
  required ChatController chat,
  required SettingsController settings,
  required AuthController auth,
}) => MaterialShadcnApp(
  theme: proculLightTheme,
  darkTheme: proculDarkTheme,
  themeMode: settings.themeMode,
  builder: (context, child) => ShadcnMaterialBridge(child: child!),
  home: HomeShell(chat: chat, settings: settings, auth: auth),
);

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  testWidgets('renders the sidebar and empty state on wide screens', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1200, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    final client = MockClient(
      (request) async => http.Response('{"conversations":[]}', 200),
    );
    final chat = ChatController(
      api: PolicyChatApi(
        baseUrl: 'http://test',
        token: 'test-token',
        client: client,
      ),
      store: FakeConversationStore(),
    );
    final settings = SettingsController();

    await tester.pumpWidget(
      _app(chat: chat, settings: settings, auth: _auth()),
    );
    await tester.pumpAndSettle();

    expect(find.text('Procul'), findsOneWidget);
    expect(find.text('New chat'), findsWidgets);
    expect(find.text('What can we work on?'), findsWidgets);
    expect(tester.takeException(), isNull);
  });

  testWidgets('sending a message renders a streamed markdown reply', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1200, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    final client = MockClient.streaming((request, body) async {
      return http.StreamedResponse(
        Stream.value(utf8.encode(_sse)),
        200,
        headers: {'content-type': 'text/event-stream'},
      );
    });
    final chat = ChatController(
      api: PolicyChatApi(
        baseUrl: 'http://test',
        token: 'test-token',
        client: client,
      ),
      store: FakeConversationStore(),
    );
    final settings = SettingsController();

    await tester.pumpWidget(
      _app(chat: chat, settings: settings, auth: _auth()),
    );
    await tester.pumpAndSettle();

    await tester.enterText(find.byKey(const Key('message-input')), 'Hi');
    await tester.testTextInput.receiveAction(TextInputAction.send);
    await tester.pumpAndSettle();

    expect(find.byType(GptMarkdown), findsOneWidget);
    expect(find.text('Greeting'), findsWidgets);
    expect(tester.takeException(), isNull);
  });

  testWidgets('narrow layout opens the conversation drawer', (tester) async {
    await tester.binding.setSurfaceSize(const Size(500, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    final client = MockClient(
      (request) async => http.Response('{"conversations":[]}', 200),
    );
    final chat = ChatController(
      api: PolicyChatApi(
        baseUrl: 'http://test',
        token: 'test-token',
        client: client,
      ),
      store: FakeConversationStore(),
    );
    final settings = SettingsController();

    await tester.pumpWidget(
      _app(chat: chat, settings: settings, auth: _auth()),
    );
    await tester.pumpAndSettle();

    // The sidebar is hidden until the menu button is tapped.
    expect(find.text('Procul'), findsNothing);

    await tester.tap(find.byIcon(LucideIcons.panelLeft));
    await tester.pumpAndSettle();

    expect(find.text('Procul'), findsOneWidget);
    expect(find.text('Settings'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'a swipe from anywhere opens the drawer and a swipe back closes it',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(500, 800));
      addTearDown(() => tester.binding.setSurfaceSize(null));

      final client = MockClient(
        (request) async => http.Response('{"conversations":[]}', 200),
      );
      final chat = ChatController(
        api: PolicyChatApi(
          baseUrl: 'http://test',
          token: 'test-token',
          client: client,
        ),
        store: FakeConversationStore(),
      );

      await tester.pumpWidget(
        _app(chat: chat, settings: SettingsController(), auth: _auth()),
      );
      await tester.pumpAndSettle();
      expect(find.text('Procul'), findsNothing);

      // A rightward drag from the *middle* of the surface opens the drawer (not
      // just the left edge — Android's back gesture owns that).
      final open = await tester.startGesture(const Offset(250, 400));
      for (var i = 0; i < 4; i++) {
        await open.moveBy(const Offset(60, 0));
        await tester.pump();
      }
      await open.up();
      await tester.pumpAndSettle();
      expect(find.text('Procul'), findsOneWidget);

      // A leftward drag over the open drawer closes it again.
      final close = await tester.startGesture(const Offset(250, 400));
      for (var i = 0; i < 4; i++) {
        await close.moveBy(const Offset(-60, 0));
        await tester.pump();
      }
      await close.up();
      await tester.pumpAndSettle();
      expect(find.text('Procul'), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('settings opens as a pane and switches the theme mode', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1200, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    final client = MockClient(
      (request) async => http.Response('{"conversations":[]}', 200),
    );
    final chat = ChatController(
      api: PolicyChatApi(
        baseUrl: 'http://test',
        token: 'test-token',
        client: client,
      ),
      store: FakeConversationStore(),
    );
    final settings = SettingsController();

    await tester.pumpWidget(
      _app(chat: chat, settings: settings, auth: _auth()),
    );
    await tester.pumpAndSettle();

    expect(settings.isDark, isTrue);
    expect(find.byType(SettingsScreen), findsNothing);

    await tester.tap(find.text('Settings'));
    await tester.pumpAndSettle();

    // Settings is a full pane, not a popup.
    expect(find.byType(SettingsScreen), findsOneWidget);
    expect(find.text('Appearance'), findsOneWidget);
    expect(find.text('Light'), findsOneWidget);
    expect(find.text('Dark'), findsOneWidget);
    expect(find.text('System'), findsOneWidget);

    await tester.tap(find.text('Light'));
    await tester.pumpAndSettle();
    expect(settings.themeMode, ThemeMode.light);
    expect(tester.takeException(), isNull);
  });

  testWidgets('Enter sends while Shift+Enter inserts a newline', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1200, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    final client = MockClient.streaming((request, body) async {
      return http.StreamedResponse(
        Stream.value(utf8.encode(_sse)),
        200,
        headers: {'content-type': 'text/event-stream'},
      );
    });
    final chat = ChatController(
      api: PolicyChatApi(
        baseUrl: 'http://test',
        token: 'test-token',
        client: client,
      ),
      store: FakeConversationStore(),
    );
    final settings = SettingsController();

    await tester.pumpWidget(
      _app(chat: chat, settings: settings, auth: _auth()),
    );
    await tester.pumpAndSettle();

    await tester.enterText(find.byKey(const Key('message-input')), 'Hi');

    // Shift+Enter must edit the text, not merely avoid submitting.
    await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
    await tester.pumpAndSettle();
    expect(find.byType(GptMarkdown), findsNothing);
    expect(
      tester
          .widget<TextField>(find.byKey(const Key('message-input')))
          .controller!
          .text,
      'Hi\n',
    );

    // A plain Enter submits the message.
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();
    expect(find.byType(GptMarkdown), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('the sidebar Usage entry opens the usage dashboard', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1200, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    final usage = jsonEncode({
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
      ],
      'models': <dynamic>[],
    });

    final client = MockClient((request) async {
      if (request.url.path.startsWith('/v1/usage')) {
        return http.Response(usage, 200);
      }
      return http.Response('{"conversations":[]}', 200);
    });
    final chat = ChatController(
      api: PolicyChatApi(
        baseUrl: 'http://test',
        token: 'test-token',
        client: client,
      ),
      store: FakeConversationStore(),
    );

    await tester.pumpWidget(
      _app(chat: chat, settings: SettingsController(), auth: _auth()),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('Usage'));
    await tester.pumpAndSettle();

    expect(find.text('Lifetime'), findsOneWidget);
    expect(find.text('Daily usage'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('the sidebar Models entry opens the model catalog', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1200, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    final client = MockClient((request) async {
      if (request.url.path == '/v1/models') {
        return http.Response(jsonEncode(testModelsJson), 200);
      }
      return http.Response('{"conversations":[]}', 200);
    });
    final chat = ChatController(
      api: PolicyChatApi(
        baseUrl: 'http://test',
        token: 'test-token',
        client: client,
      ),
      store: FakeConversationStore(),
    );

    await tester.pumpWidget(
      _app(chat: chat, settings: SettingsController(), auth: _auth()),
    );
    await tester.pumpAndSettle();

    // The footer has three entries; the middle one opens the catalog.
    expect(find.text('Usage'), findsOneWidget);
    expect(find.text('Models'), findsOneWidget);
    expect(find.text('Settings'), findsOneWidget);

    await tester.tap(find.text('Models'));
    await tester.pumpAndSettle();

    expect(find.text('Models configured on this server'), findsOneWidget);
    // Also shown in the app-bar picker, so allow both.
    expect(find.text('GPT-4o mini'), findsWidgets);
    expect(find.text('Fast and cheap'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('the sidebar puts chats before utility navigation', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1200, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    final client = MockClient(
      (request) async => http.Response('{"conversations":[]}', 200),
    );
    final chat = ChatController(
      api: PolicyChatApi(
        baseUrl: 'http://test',
        token: 'test-token',
        client: client,
      ),
      store: FakeConversationStore(),
    );

    await tester.pumpWidget(
      _app(chat: chat, settings: SettingsController(), auth: _auth()),
    );
    await tester.pumpAndSettle();

    // Utility destinations stay together below the conversations.
    expect(find.text('Usage'), findsOneWidget);
    expect(find.text('Models'), findsOneWidget);
    expect(find.text('Settings'), findsOneWidget);
    final usageY = tester.getTopLeft(find.text('Usage')).dy;
    final modelsY = tester.getTopLeft(find.text('Models')).dy;
    final settingsY = tester.getTopLeft(find.text('Settings')).dy;
    final newChatY = tester
        .getTopLeft(
          find.descendant(
            of: find.byType(ConversationSidebar),
            matching: find.text('New chat'),
          ),
        )
        .dy;
    expect(usageY, lessThan(modelsY));
    expect(modelsY, lessThan(settingsY));
    expect(newChatY, lessThan(usageY));

    // A divider separates the section entries from the chats.
    expect(
      find.descendant(
        of: find.byType(ConversationSidebar),
        matching: find.byType(Divider),
      ),
      findsOneWidget,
    );

    // The active section reads as selected after opening it.
    await tester.tap(find.text('Models'));
    await tester.pumpAndSettle();
    expect(find.text('Models configured on this server'), findsOneWidget);
  });
}
