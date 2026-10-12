# App icon source

Drop a **1024×1024 px, opaque PNG** named `icon.png` in this directory, then run:

```bash
dart run flutter_launcher_icons
```

from `frontend/`. The `flutter_launcher_icons` block in `pubspec.yaml` regenerates
every platform's icon files (Android mipmaps + adaptive, iOS/macOS asset
catalogs, Windows `.ico`, web PWA icons). Commit the generated icons.

`docs/flutter-builds.md` documents exactly where each platform's icons live.
