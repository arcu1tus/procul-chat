import 'package:flutter/material.dart' as material;
import 'package:flutter_test/flutter_test.dart';
import 'package:procul_chat_flutter/src/app_theme.dart';
import 'package:shadcn_flutter/shadcn_flutter.dart';
import 'package:shadcn_flutter_material/shadcn_flutter_material.dart';

/// `gpt_markdown` renders through `package:flutter/material.dart`, which is a
/// different library from the `material_ui` theme [MaterialShadcnApp] installs.
/// Without [ShadcnMaterialBridge] the markdown sees no Material theme and falls
/// back to Material's default light scheme, so in dark mode its code blocks turn
/// near-white and its headings and rules use the wrong greys.
void main() {
  Future<material.ThemeData> pumpWithMode(
    WidgetTester tester,
    ThemeMode mode,
  ) async {
    late material.ThemeData seen;
    await tester.pumpWidget(
      MaterialShadcnApp(
        theme: proculLightTheme,
        darkTheme: proculDarkTheme,
        themeMode: mode,
        builder: (context, child) =>
            ShadcnMaterialBridge(child: child ?? const SizedBox.shrink()),
        home: Builder(
          builder: (context) {
            seen = material.Theme.of(context);
            return const SizedBox();
          },
        ),
      ),
    );
    await tester.pumpAndSettle();
    return seen;
  }

  testWidgets('dark mode gives the markdown a dark Material theme', (
    tester,
  ) async {
    final theme = await pumpWithMode(tester, ThemeMode.dark);

    expect(theme.brightness, material.Brightness.dark);
    // The code-block surface must stay dark, not Material's near-white default.
    expect(
      theme.colorScheme.surfaceContainer.computeLuminance(),
      lessThan(0.5),
    );
    // Body and headings need light-on-dark contrast.
    expect(theme.colorScheme.onSurface.computeLuminance(), greaterThan(0.5));
  });

  testWidgets('light mode gives the markdown a light Material theme', (
    tester,
  ) async {
    final theme = await pumpWithMode(tester, ThemeMode.light);

    expect(theme.brightness, material.Brightness.light);
    expect(
      theme.colorScheme.surfaceContainer.computeLuminance(),
      greaterThan(0.5),
    );
    expect(theme.colorScheme.onSurface.computeLuminance(), lessThan(0.5));
  });
}
