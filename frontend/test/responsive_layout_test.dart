import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:procul_chat_flutter/src/app_theme.dart';
import 'package:procul_chat_flutter/src/auth_api.dart';
import 'package:procul_chat_flutter/src/auth_controller.dart';
import 'package:procul_chat_flutter/src/chat_api.dart';
import 'package:procul_chat_flutter/src/chat_controller.dart';
import 'package:procul_chat_flutter/src/home_shell.dart';
import 'package:procul_chat_flutter/src/settings_controller.dart';
import 'package:shadcn_flutter/shadcn_flutter.dart';
import 'package:shadcn_flutter_material/shadcn_flutter_material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/fake_conversation_store.dart';
import 'support/fake_credential_store.dart';
import 'support/fake_server_store.dart';

/// The shell's wide/narrow breakpoint (`HomeShell._sidebarBreakpoint`).
const double _breakpoint = 840;

AuthController _auth() => AuthController(
  api: AuthApi(client: MockClient((_) async => http.Response('{}', 200))),
  credentials: FakeCredentialStore(),
  store: FakeServerStore(),
);

/// The surface sizes the app must survive: a small phone, a tablet, a desktop,
/// and an ultra-wide monitor. Each must lay out without an overflow, and keep
/// the composer and the sidebar/menu affordance reachable.
const _sizes = <Size>[
  Size(360, 640),
  Size(768, 1024),
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
}
