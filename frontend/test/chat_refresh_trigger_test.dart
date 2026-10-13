import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:procul_chat_flutter/src/app_theme.dart';
import 'package:procul_chat_flutter/src/widgets/chat_refresh_trigger.dart';
import 'package:shadcn_flutter/shadcn_flutter.dart';
import 'package:shadcn_flutter_material/shadcn_flutter_material.dart';

Widget _app({
  required ScrollController controller,
  required ScrollPhysics physics,
  required Future<void> Function()? onRefresh,
  int count = 40,
}) => MaterialShadcnApp(
  theme: proculLightTheme,
  home: Center(
    child: SizedBox(
      width: 400,
      height: 300,
      child: ChatRefreshTrigger(
        onRefresh: onRefresh,
        child: ListView.builder(
          controller: controller,
          reverse: true,
          physics: physics,
          itemCount: count,
          itemExtent: 60,
          itemBuilder: (_, index) => Text('Message $index'),
        ),
      ),
    ),
  ),
);

void main() {
  for (final physics in <ScrollPhysics>[
    const AlwaysScrollableScrollPhysics(parent: ClampingScrollPhysics()),
    const AlwaysScrollableScrollPhysics(parent: BouncingScrollPhysics()),
  ]) {
    for (final bottom in [true, false]) {
      testWidgets(
        'pull at the ${bottom ? 'bottom' : 'top'} refreshes with $physics',
        (tester) async {
          final controller = ScrollController();
          addTearDown(controller.dispose);
          var calls = 0;
          await tester.pumpWidget(
            _app(
              controller: controller,
              physics: physics,
              onRefresh: () async => calls++,
            ),
          );
          await tester.pumpAndSettle();
          if (!bottom) controller.jumpTo(controller.position.maxScrollExtent);
          await tester.pumpAndSettle();

          await tester.drag(
            find.byType(ListView),
            Offset(0, bottom ? -240 : 240),
          );
          await tester.pumpAndSettle();
          expect(calls, 1);
          expect(tester.takeException(), isNull);
        },
      );
    }
  }

  testWidgets('short chats can refresh from the bottom', (tester) async {
    final controller = ScrollController();
    addTearDown(controller.dispose);
    var calls = 0;
    await tester.pumpWidget(
      _app(
        controller: controller,
        physics: const AlwaysScrollableScrollPhysics(),
        count: 1,
        onRefresh: () async => calls++,
      ),
    );
    await tester.pumpAndSettle();
    await tester.drag(find.byType(ListView), const Offset(0, -240));
    await tester.pumpAndSettle();
    expect(calls, 1);
  });

  testWidgets(
    'scrolling through the middle and small edge pulls do not refresh',
    (tester) async {
      final controller = ScrollController();
      addTearDown(controller.dispose);
      var calls = 0;
      await tester.pumpWidget(
        _app(
          controller: controller,
          physics: const AlwaysScrollableScrollPhysics(),
          onRefresh: () async => calls++,
        ),
      );
      await tester.pumpAndSettle();
      controller.jumpTo(controller.position.maxScrollExtent / 2);
      await tester.pumpAndSettle();
      await tester.drag(find.byType(ListView), const Offset(0, -120));
      await tester.pumpAndSettle();
      expect(calls, 0);
      controller.jumpTo(0);
      await tester.pumpAndSettle();
      await tester.drag(find.byType(ListView), const Offset(0, -40));
      await tester.pumpAndSettle();
      expect(calls, 0);
    },
  );

  testWidgets('a disabled trigger ignores pulls', (tester) async {
    final controller = ScrollController();
    addTearDown(controller.dispose);
    await tester.pumpWidget(
      _app(
        controller: controller,
        physics: const AlwaysScrollableScrollPhysics(),
        onRefresh: null,
      ),
    );
    await tester.pumpAndSettle();
    await tester.drag(find.byType(ListView), const Offset(0, -240));
    await tester.pumpAndSettle();
    expect(find.byType(DefaultRefreshIndicator), findsNothing);
  });

  testWidgets('pulls while refreshing do not start another request', (
    tester,
  ) async {
    final controller = ScrollController();
    addTearDown(controller.dispose);
    final gate = Completer<void>();
    var calls = 0;
    await tester.pumpWidget(
      _app(
        controller: controller,
        physics: const AlwaysScrollableScrollPhysics(),
        onRefresh: () async {
          calls++;
          await gate.future;
        },
      ),
    );
    await tester.pumpAndSettle();
    await tester.drag(find.byType(ListView), const Offset(0, -240));
    await tester.pump();
    expect(find.byType(DefaultRefreshIndicator), findsOneWidget);
    await tester.drag(find.byType(ListView), const Offset(0, -240));
    await tester.pump();
    expect(calls, 1);
    gate.complete();
    await tester.pumpAndSettle();
    expect(find.byType(DefaultRefreshIndicator), findsNothing);
  });
}
