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

  test(
    'theme mode round-trips across controllers (light, dark, system)',
    () async {
      SharedPreferences.setMockInitialValues({});

      for (final mode in [ThemeMode.light, ThemeMode.dark, ThemeMode.system]) {
        final first = SettingsController(store: SettingsStore());
        await first.init();
        await first.setThemeMode(mode);
        expect(first.themeMode, mode);
        expect(first.isDark, mode == ThemeMode.dark);

        final second = SettingsController(store: SettingsStore());
        await second.init();
        expect(second.themeMode, mode);
      }
    },
  );
}
