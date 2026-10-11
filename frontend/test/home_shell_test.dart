import 'dart:convert';

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
    expect(find.text('How can I help?'), findsOneWidget);
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

  testWidgets('settings dialog toggles dark mode', (tester) async {
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
    expect(find.text('Dark mode'), findsOneWidget);

    await tester.tap(find.byType(Switch));
    await tester.pumpAndSettle();
    expect(settings.isDark, isFalse);
    expect(tester.takeException(), isNull);
  });
}
