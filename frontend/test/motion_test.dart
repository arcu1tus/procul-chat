import 'package:flutter_test/flutter_test.dart';
import 'package:procul_chat_flutter/src/app_theme.dart';
import 'package:procul_chat_flutter/src/motion.dart';
import 'package:procul_chat_flutter/src/responsive.dart';
import 'package:shadcn_flutter/shadcn_flutter.dart';
import 'package:shadcn_flutter_material/shadcn_flutter_material.dart';

void main() {
  test('motion tokens are ordered and curves are set', () {
    expect(Motion.fast.inMilliseconds, lessThan(Motion.medium.inMilliseconds));
    expect(Motion.medium.inMilliseconds, lessThan(Motion.slow.inMilliseconds));
    expect(Motion.curve, isA<Curve>());
    expect(Motion.emphasized, isA<Curve>());
    expect(Motion.pop, isA<Curve>());
    expect(Motion.stagger(3).inMilliseconds, greaterThan(0));
  });

  testWidgets('reduceMotion reflects the platform accessibility setting', (
    tester,
  ) async {
    late BuildContext ctx;
    late bool reduced;
    await tester.pumpWidget(
      MaterialShadcnApp(
        theme: proculLightTheme,
        darkTheme: proculDarkTheme,
        home: Builder(
          builder: (context) {
            ctx = context;
            reduced = reduceMotion(context);
            return const SizedBox.shrink();
          },
        ),
      ),
    );
    expect(reduced, isFalse);
    expect(motionDuration(ctx, Motion.medium), Motion.medium);

    await tester.pumpWidget(
      MaterialShadcnApp(
        theme: proculLightTheme,
        darkTheme: proculDarkTheme,
        builder: (context, child) {
          final media = MediaQuery.of(context);
          return MediaQuery(
            data: media.copyWith(disableAnimations: true),
            child: child ?? const SizedBox.shrink(),
          );
        },
        home: Builder(
          builder: (context) {
            ctx = context;
            reduced = reduceMotion(context);
            return const SizedBox.shrink();
          },
        ),
      ),
    );
    expect(reduced, isTrue);
    // Non-essential animation collapses to zero rather than being skipped.
    expect(motionDuration(ctx, Motion.medium), Duration.zero);
  });

  test('breakpoints classify widths', () {
    expect(breakpointForWidth(320), Breakpoint.compact);
    expect(breakpointForWidth(599), Breakpoint.compact);
    expect(breakpointForWidth(600), Breakpoint.medium);
    expect(breakpointForWidth(839), Breakpoint.medium);
    expect(breakpointForWidth(840), Breakpoint.expanded);
    expect(Breakpoint.expanded.hasPersistentSidebar, isTrue);
    expect(Breakpoint.compact.hasPersistentSidebar, isFalse);
  });
}
