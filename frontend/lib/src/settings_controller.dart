import 'package:shadcn_flutter/shadcn_flutter.dart';

import 'settings_store.dart';

/// App preferences. Currently a single switch: dark mode (the default).
class SettingsController extends ChangeNotifier {
  SettingsController({SettingsStore? store})
    : _store = store ?? SettingsStore();

  final SettingsStore _store;

  ThemeMode _themeMode = ThemeMode.dark;

  ThemeMode get themeMode => _themeMode;

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

  Future<void> setDarkMode(bool dark) async {
    final mode = dark ? ThemeMode.dark : ThemeMode.light;
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
