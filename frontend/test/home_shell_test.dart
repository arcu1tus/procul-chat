import 'dart:convert';

import 'package:flutter/services.dart' show LogicalKeyboardKey;
import 'package:flutter_test/flutter_test.dart';
import 'package:gpt_markdown/gpt_markdown.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:procul_chat_flutter/src/app_theme.dart';
import 'package:procul_chat_flutter/src/chat_api.dart';
import 'package:procul_chat_flutter/src/chat_controller.dart';
import 'package:procul_chat_flutter/src/home_shell.dart';
import 'package:procul_chat_flutter/src/settings_controller.dart';
import 'package:shadcn_flutter/shadcn_flutter.dart';
import 'package:shadcn_flutter_material/shadcn_flutter_material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/fake_conversation_store.dart';

const _sse =
    'data: {"value":{"conversation":{"id":"c1","title":"Greeting",'
    '"createdAt":"2026-10-11T10:00:00Z","updatedAt":"2026-10-11T10:00:00Z"},'
    '"type":"created"}}\n\n'
    'data: {"value":{"content":"Hello **world**","type":"token"}}\n\n'
    'data: {"value":{"type":"done"}}\n\n';

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
      api: ChatApi(baseUrl: 'http://test', client: client),
      store: FakeConversationStore(),
    );
    final settings = SettingsController();

    await tester.pumpWidget(
      MaterialShadcnApp(
        theme: proculLightTheme,
        darkTheme: proculDarkTheme,
        themeMode: settings.themeMode,
        home: HomeShell(chat: chat, settings: settings),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Procul'), findsOneWidget);
    expect(find.text('New chat'), findsWidgets);
    expect(find.text('Ask Procul anything'), findsWidgets);
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
      api: ChatApi(baseUrl: 'http://test', client: client),
      store: FakeConversationStore(),
    );
    final settings = SettingsController();

    await tester.pumpWidget(
      MaterialShadcnApp(
        theme: proculLightTheme,
        darkTheme: proculDarkTheme,
        themeMode: settings.themeMode,
        home: HomeShell(chat: chat, settings: settings),
      ),
    );
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextField), 'Hi');
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
      api: ChatApi(baseUrl: 'http://test', client: client),
      store: FakeConversationStore(),
    );
    final settings = SettingsController();

    await tester.pumpWidget(
      MaterialShadcnApp(
        theme: proculLightTheme,
        darkTheme: proculDarkTheme,
        themeMode: settings.themeMode,
        home: HomeShell(chat: chat, settings: settings),
      ),
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

  testWidgets('settings dialog switches the theme mode', (tester) async {
    await tester.binding.setSurfaceSize(const Size(1200, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    final client = MockClient(
      (request) async => http.Response('{"conversations":[]}', 200),
    );
    final chat = ChatController(
      api: ChatApi(baseUrl: 'http://test', client: client),
      store: FakeConversationStore(),
    );
    final settings = SettingsController();

    await tester.pumpWidget(
      MaterialShadcnApp(
        theme: proculLightTheme,
        darkTheme: proculDarkTheme,
        themeMode: settings.themeMode,
        home: HomeShell(chat: chat, settings: settings),
      ),
    );
    await tester.pumpAndSettle();

    expect(settings.isDark, isTrue);

    await tester.tap(find.text('Settings'));
    await tester.pumpAndSettle();
    expect(find.text('Appearance'), findsOneWidget);
    expect(find.text('Light'), findsOneWidget);
    expect(find.text('Dark'), findsOneWidget);
    expect(find.text('System'), findsOneWidget);

    await tester.tap(find.text('Light'));
    await tester.pumpAndSettle();
    expect(settings.themeMode, ThemeMode.light);
    expect(tester.takeException(), isNull);
  });

  testWidgets('Enter sends while Shift+Enter does not', (tester) async {
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
      api: ChatApi(baseUrl: 'http://test', client: client),
      store: FakeConversationStore(),
    );
    final settings = SettingsController();

    await tester.pumpWidget(
      MaterialShadcnApp(
        theme: proculLightTheme,
        darkTheme: proculDarkTheme,
        themeMode: settings.themeMode,
        home: HomeShell(chat: chat, settings: settings),
      ),
    );
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextField), 'Hi');

    // Shift+Enter is left to the field, so nothing is submitted.
    await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
    await tester.pumpAndSettle();
    expect(find.byType(GptMarkdown), findsNothing);

    // A plain Enter submits the message.
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();
    expect(find.byType(GptMarkdown), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
