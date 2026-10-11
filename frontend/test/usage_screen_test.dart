import 'dart:convert';

import 'package:fl_chart/fl_chart.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:procul_chat_flutter/src/app_theme.dart';
import 'package:procul_chat_flutter/src/chat_api.dart';
import 'package:procul_chat_flutter/src/usage_screen.dart';
import 'package:shadcn_flutter/shadcn_flutter.dart';
import 'package:shadcn_flutter_material/shadcn_flutter_material.dart';

Map<String, dynamic> _breakdown({
  int input = 0,
  int output = 0,
  int cached = 0,
  int total = 0,
  int turns = 0,
}) => {
  'inputTokens': input,
  'outputTokens': output,
  'cachedInputTokens': cached,
  'totalTokens': total,
  'turns': turns,
};

final _summary = {
  'lifetime': _breakdown(
    input: 100,
    output: 50,
    cached: 20,
    total: 150,
    turns: 2,
  ),
  'days': [
    {'date': '2026-10-10', ..._breakdown(total: 0)},
    {
      'date': '2026-10-11',
      ..._breakdown(input: 100, output: 50, total: 150, turns: 1),
    },
  ],
  'models': [
    {'model': 'test/model', ..._breakdown(total: 150, turns: 1)},
  ],
};

final _empty = {
  'lifetime': _breakdown(),
  'days': [
    {'date': '2026-10-11', ..._breakdown()},
  ],
  'models': <dynamic>[],
};

Future<void> _pump(
  WidgetTester tester,
  http.Response Function(http.Request request) response,
) async {
  await tester.binding.setSurfaceSize(const Size(1000, 900));
  addTearDown(() => tester.binding.setSurfaceSize(null));

  final api = ChatApi(
    baseUrl: 'http://test',
    token: 'tok',
    client: MockClient((request) async => response(request)),
  );

  await tester.pumpWidget(
    MaterialShadcnApp(
      theme: proculLightTheme,
      darkTheme: proculDarkTheme,
      themeMode: ThemeMode.light,
      home: UsageScreen(api: api),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('shows lifetime totals, a chart, and the per-model breakdown', (
    tester,
  ) async {
    await _pump(tester, (_) => http.Response(jsonEncode(_summary), 200));

    expect(find.text('Usage'), findsWidgets);
    expect(find.text('Lifetime'), findsOneWidget);
    expect(find.text('150'), findsWidgets);
    expect(find.text('150 tokens'), findsOneWidget);
    expect(find.text('test/model'), findsOneWidget);
    expect(find.byType(BarChart), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('switching the metric and range keeps the chart', (tester) async {
    await _pump(tester, (_) => http.Response(jsonEncode(_summary), 200));

    await tester.tap(find.widgetWithText(SelectedButton, 'Input'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('7D'));
    await tester.pumpAndSettle();

    expect(find.byType(BarChart), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('shows an empty state when nothing has ever been recorded', (
    tester,
  ) async {
    await _pump(tester, (_) => http.Response(jsonEncode(_empty), 200));

    expect(find.text('No usage yet'), findsOneWidget);
    expect(find.byType(BarChart), findsNothing);
  });

  testWidgets('shows a request failure', (tester) async {
    await _pump(tester, (_) => http.Response('boom', 500));

    expect(find.textContaining('Could not load usage'), findsOneWidget);
  });

  testWidgets('pull-to-refresh refetches the summary', (tester) async {
    var requests = 0;
    await _pump(tester, (_) {
      requests++;
      return http.Response(jsonEncode(_summary), 200);
    });
    expect(requests, 1);

    final trigger = find.byType(RefreshTrigger);
    expect(trigger, findsOneWidget);
    await tester.state<RefreshTriggerState>(trigger).refresh();
    await tester.pumpAndSettle();

    expect(requests, 2);
  });
}
