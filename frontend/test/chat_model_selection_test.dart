import 'dart:async';
import 'dart:convert';

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
import 'support/model_fixtures.dart';

const _sse =
    'data: {"value":{"conversation":{"id":"c1","title":"New",'
    '"model":"local/llama",'
    '"createdAt":"2026-10-11T10:00:00Z","updatedAt":"2026-10-11T10:00:00Z"},'
    '"type":"created"}}\n\n'
    'data: {"value":{"content":"Hello","type":"token"}}\n\n'
    'data: {"value":{"type":"done"}}\n\n';

Map<String, dynamic> _conversation({String model = 'local/llama'}) => {
  'id': 'c1',
  'title': 'First',
  'model': model,
  'createdAt': '2026-10-11T10:00:00Z',
  'updatedAt': '2026-10-11T10:00:00Z',
};

AuthController _auth() => AuthController(
  api: AuthApi(client: MockClient((_) async => http.Response('{}', 200))),
  credentials: FakeCredentialStore(),
  store: FakeServerStore(),
);

Widget _app(ChatController chat) => MaterialShadcnApp(
  theme: proculLightTheme,
  darkTheme: proculDarkTheme,
  themeMode: ThemeMode.light,
  home: HomeShell(chat: chat, settings: SettingsController(), auth: _auth()),
);

/// A backend that serves the models, an optional conversation list, and SSE.
MockClient _client({
  Map<String, dynamic> models = testModelsJson,
  List<Map<String, dynamic>> conversations = const [],
  Map<String, dynamic>? putConversation,
  void Function(http.Request request)? onRequest,
  Future<void> Function()? gate,
}) {
  return MockClient((request) async {
    onRequest?.call(request);
    final path = request.url.path;

    if (path == '/v1/models') return http.Response(jsonEncode(models), 200);
    if (path == '/v1/conversations' && request.method == 'GET') {
      return http.Response(jsonEncode({'conversations': conversations}), 200);
    }
    if (path.endsWith('/messages') && request.method == 'GET') {
      return http.Response(jsonEncode({'messages': <dynamic>[]}), 200);
    }
    if (path.startsWith('/v1/usage/')) return http.Response('{}', 200);
    if (path == '/v1/conversations/' && request.method == 'POST') {
      if (gate != null) await gate();
      return http.Response(
        _sse,
        200,
        headers: {'content-type': 'text/event-stream'},
      );
    }
    if (request.method == 'PUT') {
      return http.Response(
        jsonEncode({'conversation': putConversation ?? _conversation()}),
        200,
      );
    }
    return http.Response('{}', 200);
  });
}

ChatController _chat(MockClient client, {String? stored}) => ChatController(
  api: ChatApi(baseUrl: 'http://test', token: 'tok', client: client),
  store: FakeConversationStore(stored),
);

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  testWidgets('the app-bar picker shows the active conversation model', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1200, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    final chat = _chat(_client(conversations: [_conversation()]), stored: 'c1');
    await chat.init();
    expect(chat.activeModel, 'local/llama');

    await tester.pumpWidget(_app(chat));
    await tester.pumpAndSettle();

    expect(find.text('Llama'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('selecting a model persists it server-side', (tester) async {
    await tester.binding.setSurfaceSize(const Size(1200, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    final puts = <http.Request>[];
    final chat = _chat(
      _client(
        conversations: [_conversation()],
        putConversation: _conversation(model: 'openai/gpt-4o-mini'),
        onRequest: (request) {
          if (request.method == 'PUT') {
            puts.add(request);
          }
        },
      ),
      stored: 'c1',
    );
    await chat.init();

    await tester.pumpWidget(_app(chat));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('model-picker')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('GPT-4o mini'));
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull, reason: 'after selecting');
    expect(puts, hasLength(1));
    expect(puts.single.url.path, '/v1/conversations/c1/model');
    expect(jsonDecode(puts.single.body), {'model': 'openai/gpt-4o-mini'});
    expect(chat.activeModel, 'openai/gpt-4o-mini');
    expect(find.text('GPT-4o mini'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('a pending selection is sent when the chat is created', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1200, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    final creates = <http.Request>[];
    final chat = _chat(
      _client(
        onRequest: (request) {
          if (request.method == 'POST' &&
              request.url.path == '/v1/conversations/') {
            creates.add(request);
          }
        },
      ),
    );

    await tester.pumpWidget(_app(chat));
    await tester.pumpAndSettle();

    // Pick a non-default model for the not-yet-created conversation.
    await tester.tap(find.byKey(const Key('model-picker')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Llama'));
    await tester.pumpAndSettle();

    await tester.enterText(find.byKey(const Key('message-input')), 'Hi');
    await tester.testTextInput.receiveAction(TextInputAction.send);
    await tester.pumpAndSettle();

    expect(creates, hasLength(1));
    expect(jsonDecode(creates.single.body), {
      'initialMessage': 'Hi',
      'model': 'local/llama',
    });
    expect(tester.takeException(), isNull);
  });

  testWidgets('the picker is disabled while a reply streams', (tester) async {
    await tester.binding.setSurfaceSize(const Size(1200, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    final gate = Completer<void>();
    addTearDown(() {
      if (!gate.isCompleted) gate.complete();
    });
    final chat = _chat(_client(gate: () => gate.future));

    await tester.pumpWidget(_app(chat));
    await tester.pumpAndSettle();

    unawaited(chat.send('Hi'));
    await tester.pump();
    expect(chat.isStreaming, isTrue);

    await tester.tap(find.byKey(const Key('model-picker')));
    await tester.pump();
    expect(find.byType(DropdownMenu), findsNothing);

    gate.complete();
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });

  testWidgets('the picker is hidden when only one model is configured', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1200, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    final chat = _chat(_client(models: testSingleModelJson));

    await tester.pumpWidget(_app(chat));
    await tester.pumpAndSettle();

    expect(find.text('Solo'), findsNothing);
    expect(tester.takeException(), isNull);
  });
}
