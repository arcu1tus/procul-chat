import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// The app's branding is mostly *static wiring* (display names, the launcher
/// icon source, the PWA colors) rather than Dart code, so this test guards the
/// files directly — a regression there would otherwise only show up on a real
/// device. Paths are relative to the `frontend/` package root, which is the
/// working directory under `flutter test`.
void main() {
  String read(String path) => File(path).readAsStringSync();

  test('every platform shows "Procul Chat"', () {
    expect(read('lib/main.dart'), contains("title: 'Procul Chat'"));
    expect(
      read('android/app/src/main/AndroidManifest.xml'),
      contains('android:label="Procul Chat"'),
    );

    final ios = read('ios/Runner/Info.plist');
    expect(ios, contains('<key>CFBundleDisplayName</key>'));
    expect(ios, contains('<key>CFBundleName</key>'));
    expect(ios, contains('<string>Procul Chat</string>'));

    expect(read('linux/procul-chat.desktop'), contains('Name=Procul Chat'));

    final web = jsonDecode(read('web/manifest.json')) as Map<String, dynamic>;
    expect(web['name'], 'Procul Chat');
    expect(web['short_name'], 'Procul Chat');
  });

  test('the launcher-icon source and config are in place', () {
    final pubspec = read('pubspec.yaml');
    expect(pubspec, contains('flutter_launcher_icons:'));
    expect(pubspec, contains('image_path: assets/icon/icon.png'));
    // The generated web icons use the magenta accent as their theme color.
    expect(pubspec, contains('theme_color: "#a832a0"'));
  });
}
