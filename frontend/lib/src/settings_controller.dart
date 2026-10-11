import 'package:shadcn_flutter/shadcn_flutter.dart';

import 'settings_store.dart';

/// App preferences. Currently a single setting: the theme mode (dark is the
/// default).
class SettingsController extends ChangeNotifier {
  SettingsController({SettingsStore? store})
    : _store = store ?? SettingsStore();

  final SettingsStore _store;

  ThemeMode _themeMode = ThemeMode.dark;

  ThemeMode get themeMode => _themeMode;

  /// Whether the explicitly selected theme is dark. When [themeMode] is
  /// [ThemeMode.system] this is `false`; the active brightness is resolved by
  /// the app from the platform.
  bool get isDark => _themeMode == ThemeMode.dark;

  /// Loads persisted preferences. Falls back to the defaults (dark) if nothing
  /// is stored or the read fails.
  Future<void> init() async {
    try {
      final stored = await _store.readThemeMode();
      if (stored != null) {
        _themeMode = stored;
        notifyListeners();
      }
    } catch (_) {
      // Keep the defaults.
    }
  }

  /// Sets and persists the theme mode. The three values map to the
  /// Light / Dark / System options in the settings dialog.
  Future<void> setThemeMode(ThemeMode mode) async {
    if (mode == _themeMode) return;
    _themeMode = mode;
    notifyListeners();
    try {
      await _store.writeThemeMode(mode);
    } catch (_) {
      // The preference still applies for this session.
    }
  }
}
