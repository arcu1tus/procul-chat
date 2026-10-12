# Building the Flutter client

How to produce a release build of the Procul Flutter client for every supported platform:
**Android, iOS, Linux, Windows, macOS, and web**. Prerequisites and commands below follow the
official Flutter [deployment docs](https://docs.flutter.dev/deployment) (verified against
Flutter 3.47).

The client lives in [`../frontend`](../frontend). Run every command from that directory unless a
step says otherwise.

## Before you build

```bash
cd frontend
flutter pub get
flutter analyze          # must stay clean
```

**Wire the app to your backend.** `PROCUL_API_BASE` is a **compile-time** dart-define; it is
baked into the binary and the app pre-fills the Connect screen with it. Pass it on every build:

```bash
--dart-define=PROCUL_API_BASE=https://api.example.com
```

If you omit it, the client defaults to `http://localhost:5010` (fine for local development, wrong
for anything shipped). A **release** build has no working default, so always set it.

> **Web only:** a browser client is subject to CORS, so your backend's
> `server.corsAllowedOrigins` must list the **exact origin** the app is served from (for example
> `https://app.example.com`). Native builds ignore CORS. See [the web section](#web) and
> [`configuration.md`](configuration.md#server).

Handy `just` shortcuts exist for all of these — see [`../frontend/justfile`](../frontend/justfile).

---

## Android

<details>
<summary><strong>Prerequisites, signing, and commands</strong></summary>

**Prerequisites**

- Android SDK + command-line tools (`flutter doctor` installs/validates via Android Studio).
- For a real release: an **upload keystore** and a `key.properties` file (see below).

**Sign the release build.** The generated `android/app/build.gradle.kts` ships a
`release` block that signs with the **debug** keys, so `flutter build apk` works out of the box
but is *not* store-ready. To sign properly:

1. Create an upload keystore (once):

   ```bash
   keytool -genkey -v -keystore ~/upload-keystore.jks -keyalg RSA \
     -storetype JKS -keysize 2048 -validity 10000 -alias upload
   ```

2. Create `android/key.properties` (**git-ignore it**):

   ```properties
   storePassword=<password>
   keyPassword=<password>
   keyAlias=upload
   storeFile=/absolute/path/to/upload-keystore.jks
   ```

3. Point the `release` build type at it (edit `android/app/build.gradle.kts`):

   ```kotlin
   val keystoreProperties = java.util.Properties().apply {
       val f = rootProject.file("key.properties")
       if (f.exists()) f.inputStream().use { load(it) }
   }

   android {
       signingConfigs {
           create("release") {
               keyAlias = keystoreProperties["keyAlias"] as String
               keyPassword = keystoreProperties["keyPassword"] as String
               storeFile = file(keystoreProperties["storeFile"] as String)
               storePassword = keystoreProperties["storePassword"] as String
           }
       }
       buildTypes {
           release {
               signingConfig = signingConfigs.getByName("release")
           }
       }
   }
   ```

   See the Flutter docs on [signing the app](https://docs.flutter.dev/deployment/android#sign-the-app).

**Commands**

```bash
# A fat APK (all ABIs) — simplest for sideloading and testing.
flutter build apk --release --dart-define=PROCUL_API_BASE=https://api.example.com

# Smaller, per-ABI APKs for distribution outside Play.
flutter build apk --release --split-per-abi --dart-define=PROCUL_API_BASE=https://api.example.com

# The Play Store format.
flutter build appbundle --release --dart-define=PROCUL_API_BASE=https://api.example.com
```

**Output**

| Command | Artifact |
| ------- | -------- |
| `flutter build apk` | `build/app/outputs/flutter-apk/app-release.apk` |
| `... --split-per-abi` | `build/app/outputs/flutter-apk/app-arm64-v8a-release.apk`, `app-armeabi-v7a-release.apk`, `app-x86_64-release.apk` |
| `flutter build appbundle` | `build/app/outputs/bundle/release/app-release.aab` |

**Gotchas**

- **Cleartext HTTP is blocked on Android (API 28+).** Debug builds enable it via
  `android/app/src/debug/AndroidManifest.xml` (`android:usesCleartextTraffic="true"`) so they can
  reach a plain-HTTP dev backend. **Release builds keep the secure default**, so a release app
  must talk to an **HTTPS** backend or the requests fail.
- **Reach a local backend with `adb reverse`, don't hardcode an IP.** For a USB/wireless-ADB
  device: `adb reverse tcp:5010 tcp:5010`, then `flutter run -d <device-id>` (the default base URL
  then works). For an emulator without `adb reverse`, use
  `--dart-define=PROCUL_API_BASE=http://10.0.2.2:5010`.

</details>

---

## iOS

<details>
<summary><strong>Prerequisites, signing, and commands</strong></summary>

**Prerequisites**

- **macOS with Xcode** — iOS builds are impossible on Linux/Windows.
- An [Apple Developer Program](https://developer.apple.com/programs/) membership for distribution.
- CocoaPods (`flutter doctor` will flag it).
- Register a Bundle ID and an app record on [App Store Connect](https://developer.apple.com/help/app-store-connect/).

**Commands**

```bash
flutter build ipa --release --dart-define=PROCUL_API_BASE=https://api.example.com
```

Approve automatic signing in Xcode (`open ios/Runner.xcworkspace`) the first time. Optionally
obfuscate the Dart code with `--obfuscate --split-debug-info=build/debug-info`.

**Output**

| Artifact | Path |
| -------- | ---- |
| Xcode archive | `build/ios/archive/Runner.xcarchive` |
| App Store bundle | `build/ios/ipa/*.ipa` |

**Gotchas**

- Upload via the Apple Transport app or the command line; see the
  [iOS deployment docs](https://docs.flutter.dev/deployment/ios).
- To distribute outside the App Store, choose an export method:
  `--export-method ad-hoc|development|enterprise`.

</details>

---

## Linux

<details>
<summary><strong>Prerequisites, commands, and packaging</strong></summary>

**Prerequisites** — the build toolchain and GTK dev headers:

```bash
sudo apt-get update -y
sudo apt-get install -y clang cmake ninja-build pkg-config libgtk-3-dev libstdc++-12-dev
```

At **runtime** the app also needs the GTK libraries (and, for the secure token store, `libsecret`
plus a running keyring — see [`../frontend/AGENTS.md`](../frontend/AGENTS.md#secure-storage--platforms)).

**Command**

```bash
flutter build linux --release --dart-define=PROCUL_API_BASE=https://api.example.com
```

**Output** — a self-contained bundle:

```
build/linux/x64/release/bundle/
├── procul_chat_flutter          # the executable
├── lib/                         # required .so libraries
└── data/                        # fonts, assets, ...
```

Ship the whole `bundle/` directory. Verify the target system's libraries with
`ldd build/linux/x64/release/bundle/procul_chat_flutter`. For a Snap, see the
[Linux deployment docs](https://docs.flutter.dev/deployment/linux).

</details>

---

## Windows

<details>
<summary><strong>Prerequisites, command, and packaging</strong></summary>

**Prerequisites** — Windows and **Visual Studio** (not VS Code) with the
**"Desktop development with C++"** workload installed. Verify with `flutter doctor -v`
(the *Visual Studio - develop Windows apps* section).

**Command**

```powershell
flutter build windows --release --dart-define=PROCUL_API_BASE=https://api.example.com
```

**Output**

```
build\windows\x64\runner\Release\
├── procul_chat_flutter.exe
├── flutter_windows.dll
└── data\
```

(The official docs show `build\windows\runner\Release`; recent Flutter versions nest the
architecture directory, e.g. `x64`.)

**Packaging** — ship the `.exe`, all `.dll` files, and the `data\` directory, plus the Visual C++
redistributables (`msvcp140.dll`, `vcruntime140.dll`, `vcruntime140_1.dll`). Or build an MSIX with
the [`msix` package](https://pub.dev/packages/msix). See the
[Windows deployment docs](https://docs.flutter.dev/platform-integration/windows/building).

</details>

---

## macOS

<details>
<summary><strong>Prerequisites, command, and distribution</strong></summary>

**Prerequisites** — macOS with **Xcode** and CocoaPods; a signed build requires a signing
certificate in Xcode.

**Command**

```bash
flutter build macos --release --dart-define=PROCUL_API_BASE=https://api.example.com
```

**Output**

```
build/macos/Build/Products/Release/procul_chat_flutter.app
```

For distribution, open `macos/Runner.xcworkspace`, then notarize (outside the App Store) or
submit (App Store). A network client needs the `com.apple.security.network.client` entitlement;
manage entitlements in `macos/Runner/*.entitlements`. See the
[macOS deployment docs](https://docs.flutter.dev/deployment/macos).

</details>

---

## Web

<details>
<summary><strong>Prerequisites, commands, serving, and CORS</strong></summary>

**Prerequisites** — none beyond the Flutter SDK. The output is static files.

**Commands**

```bash
# Standard JavaScript build.
flutter build web --release --dart-define=PROCUL_API_BASE=https://api.example.com

# Opt in to WebAssembly (faster, but needs COOP/COEP headers on the server — see below).
flutter build web --release --wasm --dart-define=PROCUL_API_BASE=https://api.example.com

# Add source maps for a crash-reporting service (keep the .map files private).
flutter build web --release --source-maps --dart-define=PROCUL_API_BASE=https://api.example.com
```

**Output** — static assets in `build/web/` (`index.html`, `main.dart.js`, `flutter_bootstrap.js`,
assets, ...).

Serve it from any static host:

```bash
cd build/web && python3 -m http.server 8000   # then open http://localhost:8000
```

**CORS — the important part.** A web build is a **browser** client, so the backend must approve
its origin. Set the backend's `server.corsAllowedOrigins` to the app's exact origin:

```jsonc
"server": { "corsAllowedOrigins": ["https://app.example.com"] }
```

In **development only**, an empty list allows any origin, so `flutter run -d chrome` works without
configuration. Outside development there is **no wildcard**: an unlisted origin is blocked by the
browser before a request reaches the server. See [`configuration.md`](configuration.md#server).

**Gotchas**

- **Streaming may buffer on the web.** On desktop/mobile, SSE streams incrementally through
  `http.Client.send()`; on the web the browser's `fetch`/XHR layer buffers by default, so replies
  may appear all at once. This is a platform limitation, not a backend bug.
- **WebAssembly needs COOP/COEP headers** on the web server
  (`Cross-Origin-Opener-Policy: same-origin`, `Cross-Origin-Embedder-Policy: credentialless`).
- **Exclude source maps from public hosting** if you generated them — upload the `.map` files to
  your private error monitor, not your CDN.

</details>

---

## App name & icon

The display name is **"Procul Chat"** on every platform (the pubspec package name stays
`procul_chat_flutter`). The strings live in:

| Platform | Where |
| -------- | ----- |
| Android | `android/app/src/main/AndroidManifest.xml` → `android:label` |
| iOS | `ios/Runner/Info.plist` → `CFBundleDisplayName` + `CFBundleName` |
| macOS | `macos/Runner/Info.plist` → `CFBundleDisplayName` |
| Windows | `windows/runner/main.cpp` window title + `windows/runner/Runner.rc` product strings |
| Linux | `linux/runner/my_application.cc` window/header title; `linux/procul-chat.desktop` |
| Web | `web/manifest.json` (`name`/`short_name`) + `web/index.html` (`<title>`, `apple-mobile-web-app-title`) |
| Dart | `main.dart` → `MaterialShadcnApp(title: 'Procul Chat')` |

### Generating the icons

Icons are generated from one source image with
[`flutter_launcher_icons`](https://pub.dev/packages/flutter_launcher_icons) (a dev dependency,
configured under `flutter_launcher_icons:` in `frontend/pubspec.yaml`).

1. Drop a **1024×1024 px, opaque PNG** at **`frontend/assets/icon/icon.png`**.
2. From `frontend/`:

   ```bash
   dart run flutter_launcher_icons
   ```

3. Commit the regenerated icons.

| Platform | Path(s) | Size(s) |
| -------- | ------- | ------- |
| Android (legacy) | `android/app/src/main/res/mipmap-{mdpi,hdpi,xhdpi,xxhdpi,xxxhdpi}/ic_launcher.png` | 48, 72, 96, 144, 192 |
| Android (adaptive) | `mipmap-anydpi-v26/ic_launcher.xml` + foreground/background drawables | `108dp` |
| iOS | `ios/Runner/Assets.xcassets/AppIcon.appiconset/Icon-App-*.png` + `Contents.json` | 20/29/40/60/76/83.5 pt @1x–3x + 1024 |
| macOS | `macos/Runner/Assets.xcassets/AppIcon.appiconset/app_icon_{16,32,64,128,256,512,1024}.png` | 16…1024 |
| Windows | `windows/runner/resources/app_icon.ico` | multi-size ICO (16…256) |
| Web | `web/icons/Icon-192.png`, `Icon-512.png`, `Icon-maskable-192.png`, `Icon-maskable-512.png`, `web/favicon.png` | 192/512 |
| Linux | no icon file by convention; ship `linux/procul-chat.desktop` + a themed icon (`hicolor/<size>/apps/procul-chat.png`) | 16…512 |

The accent color is **`#a832a0`** (`lib/src/app_theme.dart`; also the web `theme_color`).

---

## The `PROCUL_API_BASE` pattern

`frontend/lib/src/config.dart` reads the value at compile time:

```dart
const apiBaseUrl = String.fromEnvironment('PROCUL_API_BASE', defaultValue: 'http://localhost:5010');
```

So `--dart-define` is needed on **every** platform's build/run command, and changing the backend
URL requires a rebuild (it is not a runtime setting). Once the app is running, the user can still
point it at a different backend from the Connect screen by adding a server profile.

## Related pages

- **[`vps-deploy.md`](vps-deploy.md)** — building the Android APK on a Linux VPS, alongside the
  backend it talks to.
- **[`docker-compose.md`](docker-compose.md)** — run the backend the client connects to.
- **[`configuration.md`](configuration.md)** — every `config.jsonc` field (including the CORS
  origins a web build needs).
