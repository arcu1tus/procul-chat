import 'package:flutter/material.dart' as material;
import 'package:google_fonts/google_fonts.dart';
import 'package:shadcn_flutter/shadcn_flutter.dart';

/// Procul's shadcn themes.
///
/// Warm paper and charcoal surfaces with the logo's magenta accent.
/// Inter is the UI face; GeistMono stays on for code. Dark mode is the default.
const _accent = Color(0xFFA832A0);

/// The UI face. Shared by the shadcn themes and the Material bridge so the
/// markdown matches.
final interTextStyle = GoogleFonts.inter();

final proculLightTheme = ThemeData(
  colorScheme: ColorSchemes.lightZinc.copyWith(
    background: () => const Color(0xFFFAF9F6),
    foreground: () => const Color(0xFF292826),
    card: () => const Color(0xFFFFFFFF),
    muted: () => const Color(0xFFF0EEEA),
    mutedForeground: () => const Color(0xFF706D68),
    secondary: () => const Color(0xFFF0EEEA),
    accent: () => const Color(0xFFECE8E3),
    border: () => const Color(0xFFE2DED8),
    input: () => const Color(0xFFE2DED8),
    primary: () => _accent,
    primaryForeground: () => const Color(0xFFFFFFFF),
    ring: () => _accent,
  ),
  typography: Typography.geist(sans: interTextStyle),
  radius: 0.625,
);

final proculDarkTheme = ThemeData(
  colorScheme: ColorSchemes.darkZinc.copyWith(
    background: () => const Color(0xFF1B1B1D),
    foreground: () => const Color(0xFFF3F1ED),
    card: () => const Color(0xFF242426),
    muted: () => const Color(0xFF242426),
    mutedForeground: () => const Color(0xFFA5A29C),
    secondary: () => const Color(0xFF2D2C2F),
    accent: () => const Color(0xFF323035),
    border: () => const Color(0xFF39373B),
    input: () => const Color(0xFF39373B),
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
        fontFamily: theme.typography.sans.fontFamily,
        fontFamilyFallback: theme.typography.sans.fontFamilyFallback,
      ),
    );
    return material.Theme(
      data: materialTheme,
      // MaterialLayer installs a Roboto DefaultTextStyle inside ShadcnApp.
      // Restore the app's typography below that layer as well as theming Markdown.
      child: DefaultTextStyle(
        style: theme.typography.sans.copyWith(
          fontSize: 16,
          color: colors.foreground,
        ),
        child: child,
      ),
    );
  }
}
