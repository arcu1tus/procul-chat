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
