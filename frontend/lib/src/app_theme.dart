import 'package:flutter/material.dart' as material;
import 'package:google_fonts/google_fonts.dart';
import 'package:shadcn_flutter/shadcn_flutter.dart';

/// Procul's shadcn themes.
///
/// Both are built on the neutral "zinc" palette with a magenta accent
/// (`#a832a0`), so the app reads as one cohesive design in either mode. Dark
/// mode is the default (see [SettingsController]). The UI face is Inter;
/// GeistMono (bundled by shadcn) stays on for inline code and code blocks, and
/// Coiny is used for a couple of display accents (see `GoogleFonts.coiny`).
const _accent = Color(0xFFA832A0);

/// The UI face. Shared by the shadcn themes and the Material bridge so the
/// markdown matches.
final interTextStyle = GoogleFonts.inter();

final proculLightTheme = ThemeData(
  colorScheme: ColorSchemes.lightZinc.copyWith(
    primary: () => _accent,
    primaryForeground: () => const Color(0xFFFFFFFF),
    ring: () => _accent,
  ),
  typography: Typography.geist(sans: interTextStyle),
  radius: 0.625,
);

final proculDarkTheme = ThemeData(
  colorScheme: ColorSchemes.darkZinc.copyWith(
    primary: () => _accent,
    primaryForeground: () => const Color(0xFFFFFFFF),
    ring: () => _accent,
  ),
  typography: Typography.geist(sans: interTextStyle),
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
/// shadcn palette, light/dark mode, and the Inter UI face.
class ShadcnMaterialBridge extends StatelessWidget {
  const ShadcnMaterialBridge({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final base = material.ThemeData.from(
      colorScheme: material.ColorScheme.fromSeed(
        seedColor: colors.primary,
        brightness: theme.brightness,
        surface: colors.background,
        primary: colors.primary,
        secondary: colors.secondary,
        error: colors.destructive,
      ),
    );
    final materialTheme = base.copyWith(
      textTheme: base.textTheme.apply(
        fontFamily: interTextStyle.fontFamily,
        fontFamilyFallback: interTextStyle.fontFamilyFallback,
      ),
    );
    return material.Theme(data: materialTheme, child: child);
  }
}
