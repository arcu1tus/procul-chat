import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:procul_chat_flutter/src/app_theme.dart';
import 'package:procul_chat_flutter/src/chat_api.dart';
import 'package:procul_chat_flutter/src/model_catalog_controller.dart';
import 'package:procul_chat_flutter/src/models_screen.dart';
import 'package:procul_chat_flutter/src/widgets/skeleton.dart';
import 'package:shadcn_flutter/shadcn_flutter.dart';
import 'package:shadcn_flutter_material/shadcn_flutter_material.dart';

import 'support/model_fixtures.dart';

Widget _app(ModelCatalogController catalog) => MaterialShadcnApp(
  theme: proculLightTheme,
  darkTheme: proculDarkTheme,
  themeMode: ThemeMode.light,
  home: ModelsScreen(catalog: catalog),
);

ModelCatalogController _controller(MockClient client) => ModelCatalogController(
  api: ChatApi(baseUrl: 'http://test', token: 'tok', client: client),
);

Future<ModelCatalogController> _pump(
  WidgetTester tester,
  http.Response Function(http.Request request) response,
) async {
  await tester.binding.setSurfaceSize(const Size(1000, 900));
  addTearDown(() => tester.binding.setSurfaceSize(null));

  final catalog = _controller(MockClient((request) async => response(request)));
  await catalog.load();

  await tester.pumpWidget(_app(catalog));
  await tester.pumpAndSettle();
  return catalog;
}

void main() {
  testWidgets('renders names, descriptions, capability badges, and health', (
    tester,
  ) async {
    await _pump(tester, (_) => http.Response(jsonEncode(testModelsJson), 200));

    expect(find.text('Models'), findsWidgets);
    expect(find.text('GPT-4o mini'), findsOneWidget);
    expect(find.text('Fast and cheap'), findsOneWidget);
    expect(find.text('Default'), findsOneWidget);
    expect(find.text('Llama'), findsOneWidget);

    // Capability badges (both models accept text; each has one extra).
    expect(find.text('Image'), findsOneWidget);
    expect(find.text('Audio'), findsOneWidget);
    expect(find.text('File'), findsOneWidget);
    expect(find.text('Text'), findsNWidgets(2));

    // Healthy vs unhealthy health rows.
    expect(find.textContaining('Healthy ·'), findsOneWidget);
    expect(find.textContaining('123 ms'), findsOneWidget);
    expect(find.textContaining('Unhealthy ·'), findsOneWidget);
    expect(
      find.textContaining('Last error: connection refused'),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('shows a loading shimmer while the first load is in flight', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1000, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    final gate = Completer<void>();
    final catalog = _controller(
      MockClient((request) async {
        await gate.future;
        return http.Response(jsonEncode(testModelsJson), 200);
      }),
    );

    // Start the load but do not await it, so the screen renders mid-flight.
    unawaited(catalog.load());
    await tester.pumpWidget(_app(catalog));
    await tester.pump();

    expect(find.byType(Shimmer), findsOneWidget);

    gate.complete();
    await tester.pumpAndSettle();
    expect(find.text('GPT-4o mini'), findsOneWidget);
  });

  testWidgets('shows an empty state when nothing is configured', (
    tester,
  ) async {
    await _pump(
      tester,
      (_) => http.Response(
        jsonEncode({'defaultModel': null, 'models': <dynamic>[]}),
        200,
      ),
    );

    expect(find.text('No models configured'), findsOneWidget);
  });

  testWidgets('shows a request failure', (tester) async {
    await _pump(tester, (_) => http.Response('boom', 500));

    expect(find.textContaining('Could not load models'), findsOneWidget);
  });

  testWidgets('"Check all" probes every model and refreshes', (tester) async {
    final gets = <String>[];
    final posts = <String>[];
    final catalog = _controller(
      MockClient((request) async {
        if (request.method == 'POST') {
          posts.add(request.url.path);
        } else {
          gets.add(request.url.path);
        }
        return http.Response(jsonEncode(testModelsJson), 200);
      }),
    );
    await catalog.load();
    expect(gets, ['/v1/models']);

    await tester.binding.setSurfaceSize(const Size(1000, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(_app(catalog));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('check-all-models')));
    await tester.pumpAndSettle();

    expect(posts, ['/v1/models/check']);
    expect(gets, ['/v1/models', '/v1/models']);
    expect(tester.takeException(), isNull);
  });

  testWidgets('a per-model Check probes just that model and refreshes', (
    tester,
  ) async {
    final gets = <String>[];
    final posts = <String>[];
    final catalog = _controller(
      MockClient((request) async {
        if (request.method == 'POST') {
          posts.add(request.url.path);
        } else {
          gets.add(request.url.path);
        }
        return http.Response(jsonEncode(testModelsJson), 200);
      }),
    );
    await catalog.load();

    await tester.binding.setSurfaceSize(const Size(1000, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(_app(catalog));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey('check-local/llama')));
    await tester.pumpAndSettle();

    expect(posts, ['/v1/models/local/llama/check']);
    expect(gets, ['/v1/models', '/v1/models']);
    expect(tester.takeException(), isNull);
  });
}
