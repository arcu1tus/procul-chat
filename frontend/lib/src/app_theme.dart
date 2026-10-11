import 'package:flutter/material.dart' as material;
import 'package:shadcn_flutter/shadcn_flutter.dart';

/// Procul's shadcn themes.
///
/// Both are built on the neutral "zinc" palette with a violet accent, so the
/// app reads as one cohesive design in either mode. Dark mode is the default
/// (see [SettingsController]).
const _lightAccent = Color(0xFF7C3AED);
const _darkAccent = Color(0xFFA78BFA);

final proculLightTheme = ThemeData(
  colorScheme: ColorSchemes.lightZinc.copyWith(
    primary: () => _lightAccent,
    primaryForeground: () => const Color(0xFFFFFFFF),
    ring: () => _lightAccent,
  ),
  radius: 0.625,
);

final proculDarkTheme = ThemeData(
  colorScheme: ColorSchemes.darkZinc.copyWith(
    primary: () => _darkAccent,
    primaryForeground: () => const Color(0xFF1E1B4B),
    ring: () => _darkAccent,
  ),
  radius: 0.625,
);

/// Bridges the ambient shadcn theme to `package:flutter/material.dart`.
///
/// `gpt_markdown` renders through `package:flutter/material.dart`, but the app
/// (and [MaterialShadcnApp]) is built on the separate `material_ui` library, so
/// nothing installs a Material `Theme` the markdown can see. Left alone it falls
/// back to Material's default *light* scheme, which is why its code blocks turn
/// near-white and its headings, rules and list markers use the wrong greys on
/// the dark UI.
///
/// Wrap the app's content in this once and every `package:flutter/material.dart`
/// widget — the markdown, its code copy button, selection toolbars — follows the
/// shadcn palette and light/dark mode.
class ShadcnMaterialBridge extends StatelessWidget {
  const ShadcnMaterialBridge({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final materialTheme = material.ThemeData.from(
      colorScheme: material.ColorScheme.fromSeed(
        seedColor: colors.primary,
        brightness: theme.brightness,
        surface: colors.background,
        primary: colors.primary,
        secondary: colors.secondary,
        error: colors.destructive,
      ),
    );
    return material.Theme(data: materialTheme, child: child);
  }
}
