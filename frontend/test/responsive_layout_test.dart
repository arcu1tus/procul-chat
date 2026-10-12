import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:procul_chat_flutter/src/app_theme.dart';
import 'package:procul_chat_flutter/src/auth_api.dart';
import 'package:procul_chat_flutter/src/auth_controller.dart';
import 'package:procul_chat_flutter/src/chat_api.dart';
import 'package:procul_chat_flutter/src/chat_controller.dart';
import 'package:procul_chat_flutter/src/conversation_sidebar.dart';
import 'package:procul_chat_flutter/src/home_shell.dart';
import 'package:procul_chat_flutter/src/settings_controller.dart';
import 'package:shadcn_flutter/shadcn_flutter.dart';
import 'package:shadcn_flutter_material/shadcn_flutter_material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/fake_conversation_store.dart';
import 'support/fake_credential_store.dart';
import 'support/fake_server_store.dart';
import 'support/model_fixtures.dart';

/// The shell's wide/narrow breakpoint (`HomeShell._sidebarBreakpoint`).
const double _breakpoint = 840;

/// A long title that would wrap one character per line if the app bar let it.
const _longTitle =
    'why is the sky blue and why does the triple dot menu do nothing here';

AuthController _auth() => AuthController(
  api: AuthApi(client: MockClient((_) async => http.Response('{}', 200))),
  credentials: FakeCredentialStore(),
  store: FakeServerStore(),
);

/// A backend with two models and one conversation with [_longTitle].
MockClient _longTitleClient() => MockClient((request) async {
  final path = request.url.path;
  if (path == '/v1/models') {
    return http.Response(jsonEncode(testModelsJson), 200);
  }
  if (path == '/v1/conversations' && request.method == 'GET') {
    return http.Response(
      jsonEncode({
        'conversations': [
          {
            'id': 'c1',
            'title': _longTitle,
            'model': 'openai/gpt-4o-mini',
            'createdAt': '2026-10-11T10:00:00Z',
            'updatedAt': '2026-10-11T10:00:00Z',
          },
        ],
      }),
      200,
    );
  }
  if (path.endsWith('/messages')) {
    return http.Response('{"messages":[]}', 200);
  }
  if (path.startsWith('/v1/usage/')) return http.Response('{}', 200);
  return http.Response('{}', 200);
});

/// The surface sizes the app must survive: a small phone, a tablet, a desktop,
/// and an ultra-wide monitor. Each must lay out without an overflow, and keep
/// the composer and the sidebar/menu affordance reachable.
const _sizes = <Size>[
  Size(320, 568),
  Size(360, 640),
  Size(390, 844),
  Size(412, 915),
  Size(768, 1024),
  Size(1024, 768),
  Size(1400, 900),
  Size(2560, 1440),
];

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  for (final size in _sizes) {
    testWidgets(
      'lays out without overflow at ${size.width.toInt()}x${size.height.toInt()}',
      (tester) async {
        await tester.binding.setSurfaceSize(size);
        addTearDown(() => tester.binding.setSurfaceSize(null));

        final client = MockClient(
          (request) async => http.Response('{"conversations":[]}', 200),
        );
        final chat = ChatController(
          api: ChatApi(
            baseUrl: 'http://test',
            token: 'test-token',
            client: client,
          ),
          store: FakeConversationStore(),
        );

        await tester.pumpWidget(
          MaterialShadcnApp(
            theme: proculLightTheme,
            darkTheme: proculDarkTheme,
            themeMode: ThemeMode.dark,
            home: HomeShell(
              chat: chat,
              settings: SettingsController(),
              auth: _auth(),
            ),
          ),
        );
        await tester.pumpAndSettle();

        expect(tester.takeException(), isNull);
        expect(find.byType(TextField), findsOneWidget);
        expect(find.bySemanticsLabel('Send message'), findsAtLeastNWidgets(1));

        if (size.width >= _breakpoint) {
          // Wide: the sidebar is persistent.
          expect(find.text('Procul'), findsOneWidget);
        } else {
          // Narrow: the sidebar is behind the menu button.
          expect(find.bySemanticsLabel('Open chats'), findsAtLeastNWidgets(1));
        }
      },
    );
  }

  // R1/R2: the chat app bar must not overflow, must not stretch to the height
  // of the screen, and the title must ellipsize on one line.
  for (final size in const [Size(320, 640), Size(360, 800)]) {
    testWidgets('the app bar stays one line with a long title at '
        '${size.width.toInt()}x${size.height.toInt()}', (tester) async {
      await tester.binding.setSurfaceSize(size);
      addTearDown(() => tester.binding.setSurfaceSize(null));

      final chat = ChatController(
        api: ChatApi(
          baseUrl: 'http://test',
          token: 'test-token',
          client: _longTitleClient(),
        ),
        store: FakeConversationStore('c1'),
      );
      await chat.init();

      await tester.pumpWidget(
        MaterialShadcnApp(
          theme: proculLightTheme,
          darkTheme: proculDarkTheme,
          themeMode: ThemeMode.dark,
          home: HomeShell(
            chat: chat,
            settings: SettingsController(),
            auth: _auth(),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(tester.takeException(), isNull);

      // The title is exactly one ellipsized line.
      final title = tester.widget<Text>(find.text(_longTitle).first);
      expect(title.maxLines, 1);
      expect(title.overflow, TextOverflow.ellipsis);

      // The bar did not grow to the height of the screen.
      final barHeight = tester.getSize(find.byType(AppBar)).height;
      expect(barHeight, lessThan(size.height / 3));
    });
  }

  // R6: the sidebar bottom clears the system navigation bar.
  testWidgets('the sidebar clears a synthetic bottom inset', (tester) async {
    await tester.binding.setSurfaceSize(const Size(1200, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    tester.view.devicePixelRatio = 1.0;
    tester.view.padding = const FakeViewPadding(bottom: 34);
    tester.view.viewPadding = const FakeViewPadding(bottom: 34);
    addTearDown(tester.view.reset);

    final chat = ChatController(
      api: ChatApi(
        baseUrl: 'http://test',
        token: 'test-token',
        client: MockClient(
          (_) async => http.Response('{"conversations":[]}', 200),
        ),
      ),
      store: FakeConversationStore(),
    );

    await tester.pumpWidget(
      MaterialShadcnApp(
        theme: proculLightTheme,
        darkTheme: proculDarkTheme,
        themeMode: ThemeMode.dark,
        home: HomeShell(
          chat: chat,
          settings: SettingsController(),
          auth: _auth(),
        ),
      ),
    );
    await tester.pumpAndSettle();

    // The sidebar reserves the bottom inset explicitly.
    expect(
      find.descendant(
        of: find.byType(ConversationSidebar),
        matching: find.byWidgetPredicate(
          (widget) => widget is SizedBox && widget.height == 34,
        ),
      ),
      findsOneWidget,
    );

    // The composer clears it too (its SafeArea honours the inset).
    expect(
      tester.getBottomLeft(find.bySemanticsLabel('Send message')).dy,
      lessThanOrEqualTo(800 - 34),
    );
    expect(tester.takeException(), isNull);
  });
}
