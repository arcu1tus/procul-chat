import 'package:flutter_test/flutter_test.dart';
import 'package:procul_chat_flutter/src/settings_controller.dart';
import 'package:procul_chat_flutter/src/settings_store.dart';
import 'package:shadcn_flutter/shadcn_flutter.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('dark mode is the default', () async {
    SharedPreferences.setMockInitialValues({});
    final controller = SettingsController(store: SettingsStore());

    expect(controller.isDark, isTrue);
    expect(controller.themeMode, ThemeMode.dark);
  });

  test('theme mode persists across controllers', () async {
    SharedPreferences.setMockInitialValues({});

    final first = SettingsController(store: SettingsStore());
    await first.init();
    await first.setDarkMode(false);
    expect(first.themeMode, ThemeMode.light);

    final second = SettingsController(store: SettingsStore());
    await second.init();
    expect(second.themeMode, ThemeMode.light);
  });
}
