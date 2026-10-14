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

If you omit it, the client prefills `http://localhost:5010` (fine for local development). This
value only prefills **Add server**; users can replace it and save their own server profiles.
For distribution, use an HTTPS default. The `just` recipes use `https://procul-api.natix.dev`
unless overridden with the `PROCUL_API_BASE` environment variable.

> **Web only:** a browser client is subject to CORS, so your backend's
> `server.corsAllowedOrigins` must list the **exact origin** the app is served from (for example
> `https://app.example.com`). Native builds ignore CORS. See [the web section](#web) and
> [`configuration.md`](configuration.md#server).

Handy `just` shortcuts exist for all of these — see [`../frontend/justfile`](../frontend/justfile).

Client behavior to check after a build: pull up at the bottom of the chat or down at its top
to refresh, including when the chat is shorter than the viewport. Refresh is disabled during
a streamed reply; the header also has a refresh action. On web and desktop, Enter sends and
Shift+Enter inserts a newline at the caret (or replaces the selected text). The mobile keyboard's
send action and the on-screen send button still submit. Refreshing after a streamed turn should
show each message once, even when prompts and replies repeat identical text.

The sidebar puts new chats and title search above the conversation list, with Usage, Models,
and Settings at the bottom. Search filters loaded chat titles locally. Welcome cards fill and
focus a draft for the user to finish; they do not send automatically. The centered composer
allows media-only messages and keeps Send disabled for empty drafts, incompatible attachments,
and while attachments are being read or uploaded, including keyboard submission.
Sign-in fields keep their labels visible and offer a password visibility toggle.

The in-app logo is bundled at `frontend/assets/brand/procul-logo.svg`, derived from the original
`assets/procul-logo.svg` with theme-aware strokes and the original magenta fills. Launcher icons
still use the PNG described below. Both themes use Inter, with warm paper / charcoal surfaces.
Motion uses eased transitions, staggered entrances, and small settling gestures, and respects
both disabled animations and accessible navigation.

For isolated welcome previews in light, dark, and phone layouts, run:

```bash
flutter widget-preview start
```

Preview definitions live in `frontend/lib/previews.dart`; no backend or sign-in is required.

## Automated CI & tagged releases

[`ci.yml`](../.github/workflows/ci.yml) runs Flutter analysis and the complete unit/widget test
suite for every pull request targeting `main` and every push to `main`, alongside backend CI.
It also tests release tag parsing. Dependencies are restored with `--enforce-lockfile`.
Flutter **3.47.7** (Dart 3.13.5) is pinned in both CI and the release workflow; update both
pins together when upgrading the SDK.

Linux unit/widget tests also compile the clipboard/drop package's Rust host assets. Both CI test
jobs install `pkg-config` and `libgtk-3-dev` first; for local Debian/Ubuntu test runs install those
packages too. GTK development headers supply the required GLib, GObject, and GDK metadata.

Push a valid `v<SemVer>` tag (for example `v1.2.3` or `v1.2.3-rc.1`) to run
[`publish-flutter-app.yml`](../.github/workflows/publish-flutter-app.yml), matching the backend's
tag-driven publishing. Other `v*` tags skip client tests/builds/publication. Tests and analysis
must pass before builds start, and all four platforms must build before publication.
No iOS or macOS build is included.

The workflow attaches these five assets to the matching GitHub Release, creating it with
generated notes if absent. SemVer prereleases create prereleases; existing release notes and
settings are preserved. Reruns replace same-named assets. No release needs to be created
manually before pushing the tag.

| Target | Release asset for `v1.2.3` | Contents |
| --- | --- | --- |
| Android | `procul-chat-android-1.2.3.apk` | Release-mode fat APK from `app-release.apk` |
| Web | `procul-chat-web-1.2.3.zip` | Whole Wasm web output, including JavaScript fallback; `index.html` at ZIP root |
| Windows x64 | `procul-chat-windows-1.2.3.zip` | EXE, Flutter/plugin DLLs, Visual C++ runtime DLLs, and `data/` |
| Linux x64 | `procul-chat-linux-1.2.3.deb` | Installable Debian/Ubuntu package |
| Linux x64 | `procul-chat-linux-1.2.3.rpm` | Installable RPM package |

The full version appears in filenames, including any prerelease/build metadata, without `v`.
Native app versions use the numeric `MAJOR.MINOR.PATCH` core and the workflow run number as
the build number. nFPM encodes Linux package versions with `~` before prerelease identifiers
so they sort before stable versions (RPM prerelease hyphens become underscores); SemVer build
metadata is omitted from package versions.
The repository Actions **variable** `PROCUL_API_BASE` sets the Add server prefill; absent that,
the workflow uses `https://procul-api.natix.dev`, matching the `just` recipes. This is not a
secret, and users can choose another server in the app.

**Distribution quirks (no custom signing).**

- Android requires every installable APK to be signed. CI retains the existing automatic
  **debug signing**, with no custom keystore or signing secrets. These APKs are for sideloading,
  not store submission. Fresh runners may generate different debug keys, preventing an in-place
  upgrade over a previous build; uninstalling first loses the app's local profiles/settings.
  See [Android's signing requirements](https://developer.android.com/studio/publish/app-signing).
- Windows Flutter apps need supporting DLLs and assets, so an EXE alone is insufficient. The
  ZIP includes the application-local Visual C++ runtime, as described in
  [Flutter's Windows ZIP packaging guide](https://docs.flutter.dev/platform-integration/windows/building#building-your-own-zip-file-for-windows).
  Extract the entire ZIP before running `procul_chat_flutter.exe`. It is unsigned, so Windows
  may show publisher/reputation warnings.
- Linux packages are unsigned and built on **Ubuntu 22.04**, requiring **glibc >=2.35**,
  **libstdc++ >=12**, GTK 3, and libsecret. nFPM's
  [configuration](../frontend/packaging/nfpm.yaml) installs the bundle in `/opt/procul-chat`,
  links `procul_chat_flutter` in `/usr/bin`, and installs the desktop launcher/icon. The package
  manager resolves distro-specific dependencies; a running Secret Service/keyring is also
  needed. An RPM format does not guarantee compatibility with every RPM distribution: older
  systems such as EL9 have a lower glibc baseline. Install with `sudo apt install ./<file>.deb`
  or `sudo dnf install ./<file>.rpm` on a compatible x64 desktop, and launch Procul Chat.
  Packages use [nFPM](https://nfpm.goreleaser.com/docs/configuration/) **2.47.0**.
- Web output needs static hosting, HTTPS (or localhost for development), API CORS, and
  COOP/COEP headers for multithreaded Skwasm. The archive contains both Wasm and JavaScript
  fallback output; no hosting is provisioned by CI. See the [web section](#web) and
  [Flutter's Wasm guide](https://docs.flutter.dev/platform-integration/web/wasm).

Only the publication job gets `contents: write`; the built-in `GITHUB_TOKEN` suffices.
Build files also remain available as Actions artifacts if publication fails.

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
sudo apt-get install -y clang cmake ninja-build pkg-config libgtk-3-dev libsecret-1-dev libstdc++-12-dev
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
# WebAssembly with automatic JavaScript fallback (also used by just build-web).
flutter build web --release --wasm --dart-define=PROCUL_API_BASE=https://api.example.com

# Build and precompress static assets; requires Python 3 and the brotli CLI.
# Debian/Ubuntu: sudo apt-get install python3 brotli
PROCUL_API_BASE=https://api.example.com just build-web-compressed

# JavaScript-only build, if needed.
flutter build web --release --dart-define=PROCUL_API_BASE=https://api.example.com

# Add source maps for a crash-reporting service (keep the .map files private).
flutter build web --release --wasm --source-maps --dart-define=PROCUL_API_BASE=https://api.example.com
```

**Output** — static assets in `build/web/` (`index.html`, `main.dart.wasm`, `main.dart.mjs`,
`main.dart.js`, `flutter_bootstrap.js`, assets, ...). Flutter chooses Wasm on supported browsers
and falls back to JavaScript elsewhere. Keep both outputs; a Wasm build does not guarantee a
smaller download or faster startup. See [Flutter's Wasm guide](https://docs.flutter.dev/platform-integration/web/wasm).

Serve it from any static host:

```bash
cd build/web && python3 -m http.server 8000   # then open http://localhost:8000
```

That simple server serves original files without compression or multithreaded rendering.

**Compressed hosting with Caddy.** `build-web-compressed` adds Brotli (quality 9) and gzip
(level 9) sidecars beside JS, MJS, Wasm, HTML, CSS, JSON, SVG, and TTF/OTF assets of at least
512 bytes. It keeps a sidecar only if smaller than the original and leaves images, WOFF fonts,
and source maps alone. To compress an existing build: `python3 tool/compress_web.py build/web`.
Copy the **whole directory**, including originals and sidecars, to the host. A `.br` file alone
does not enable compression; the HTTP server must negotiate the encoding.

Use [`frontend/deploy/Caddyfile.example`](../frontend/deploy/Caddyfile.example), or add this
site to your existing Caddyfile:

```caddyfile
app.example.com {
    root * /srv/procul-web
    header {
        Cross-Origin-Opener-Policy same-origin
        Cross-Origin-Embedder-Policy credentialless
    }
    encode zstd gzip
    file_server {
        precompressed br gzip
    }
}
```

Stock Caddy serves the `.br`/`.gz` sidecars with `Content-Encoding` and the original asset's
content type; `encode zstd gzip` compresses responses when no matching sidecar exists. No Brotli
Caddy plugin is needed. See [Caddy's file server docs](https://caddyserver.com/docs/caddyfile/directives/file_server).
The example file accepts `PROCUL_WEB_DOMAIN` (default `app.example.com`) and `PROCUL_WEB_ROOT`
(default `/srv/procul-web`) environment variables. For containerized Caddy, mount the output
read-only at that path, for example `./web:/srv/procul-web:ro`, and set the API's allowed origin.
Keep these directives in the **web app's** site block, separate from the API proxy.

For a local check from `frontend/` (stop with Ctrl+C):

```bash
PROCUL_WEB_DOMAIN=http://localhost:8000 PROCUL_WEB_ROOT="$PWD/build/web" \
  caddy run --config deploy/Caddyfile.example --adapter caddyfile
```

Verify production responses:

```bash
curl -I -H 'Accept-Encoding: br' https://app.example.com/main.dart.wasm
curl -I -H 'Accept-Encoding: gzip' https://app.example.com/main.dart.js
```

Expect `Content-Encoding: br` / `gzip`, `Vary: Accept-Encoding`, and
`Content-Type: application/wasm` on the Wasm response. In browser DevTools, check that a
supported browser requests `main.dart.wasm` and that `crossOriginIsolated` is `true` in the
console. Also check sign-in, chat, and attachment downloads after changing hosting headers.

**CORS — the important part.** A web build is a **browser** client, so the backend must approve
its origin. Set the backend's `server.corsAllowedOrigins` to the app's exact origin:

```jsonc
"server": { "corsAllowedOrigins": ["https://app.example.com"] }
```

In **development only**, an empty list allows any origin, so `flutter run -d chrome` works without
configuration. Outside development there is **no wildcard**: an unlisted origin is blocked by the
browser before a request reaches the server. See [`configuration.md`](configuration.md#server).

**Gotchas**

- **A current startup layout error appears in both web targets.** Browser smoke checks of the
  release Connect screen logged `RenderBox was not laid out` in both Wasm and the JavaScript
  fallback, although the sign-in form rendered. Check browser console errors as well as appearance.
- **Streaming may buffer on the web.** On desktop/mobile, SSE streams incrementally through
  `http.Client.send()`; on the web the browser's `fetch`/XHR layer buffers by default, so replies
  may appear all at once. This is a platform limitation, not a backend bug.
- **Multithreaded Wasm rendering needs COOP/COEP headers** on the web server
  (`Cross-Origin-Opener-Policy: same-origin`, `Cross-Origin-Embedder-Policy: credentialless`).
  Without cross-origin isolation, Skwasm uses a single thread. API CORS is still required.
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

1. Drop a **1024×1024 px PNG** at **`frontend/assets/icon/icon.png`**. A transparent
   background is fine — Android, macOS and web keep it, and iOS is flattened (see below).
2. From `frontend/`:

   ```bash
   dart run flutter_launcher_icons
   ```

3. Commit the regenerated icons.

> **iOS needs an opaque icon.** The App Store rejects icons with an alpha channel. The config
> sets `remove_alpha_ios: true`, which alpha-blends the source onto `background_color_ios`
> (`#ffffff` by default — the logo's strokes are black, so keep a light background). Without it
> the generator prints an "Icons with alpha channel are not allowed" warning and the generated
> `AppIcon` PNGs stay RGBA.
>
> **macOS and Windows need `generate: true`.** Unlike `android: true` / `ios: true`, a
> per-platform map is only honoured when it sets `generate: true`; otherwise the run logs
> "config is not provided … Skipped" and leaves the platform's stock Flutter icon in place.
> Windows also writes a **single-frame** `.ico` (one size, `icon_size`, default 48 px), so the
> config raises it to 256 px.

| Platform | Path(s) | Size(s) |
| -------- | ------- | ------- |
| Android (legacy) | `android/app/src/main/res/mipmap-{mdpi,hdpi,xhdpi,xxhdpi,xxxhdpi}/ic_launcher.png` | 48, 72, 96, 144, 192 |
| Android (adaptive) | `mipmap-anydpi-v26/ic_launcher.xml` + foreground/background drawables | `108dp` |
| iOS | `ios/Runner/Assets.xcassets/AppIcon.appiconset/Icon-App-*.png` + `Contents.json` | 20/29/40/60/76/83.5 pt @1x–3x + 1024 |
| macOS | `macos/Runner/Assets.xcassets/AppIcon.appiconset/app_icon_{16,32,64,128,256,512,1024}.png` | 16…1024 |
| Windows | `windows/runner/resources/app_icon.ico` | single-frame ICO (`windows.icon_size`, 256) |
| Web | `web/icons/Icon-192.png`, `Icon-512.png`, `Icon-maskable-192.png`, `Icon-maskable-512.png`, `web/favicon.png` | 192/512 |
| Linux | bundled `assets/icon/icon.png` for X11; install the desktop entry matching the GTK application ID + `procul-chat.png` | 16…512 |

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

## Media and native window integration

Clipboard paste and incoming drag/drop use `super_clipboard` and `super_drag_and_drop`
`0.10.0-dev.2`, locked in `pubspec.lock`. Stable `0.9.1` conflicts with the Windows `win32` version
required by secure storage 11.2.0. The prerelease uses Rust build hooks; install a Rust toolchain
for native builds, and keep Android's NDK available. Web uses browser paste events and supports
Wasm. Only incoming media is added: public image URLs are not fetched on drop.

Test Ctrl/Cmd+V, context-menu paste, selection replacement, screenshots, file drops, mixed batches,
model changes, and count/size/type limits on available targets. Browser/OS clipboard permissions
and virtual-file support differ; the picker remains available. Response reasoning/tool details
are expandable on touch and keyboard and persist after refresh.

Linux uses ordinary GTK window decorations rather than forcing a GTK header bar. Check native
KDE Plasma controls, dragging, resizing, and maximize/minimize/close on Wayland and X11. GNOME
may supply its own client decoration. X11 loads the bundled PNG relative to the executable, so
unpackaged builds also have the Procul icon. Wayland uses the installed desktop entry; nFPM
installs `com.example.procul_chat_flutter.desktop` to match `APPLICATION_ID` in Linux CMake,
with the same `StartupWMClass`. Keep these identifiers synchronized. Session restoration is verified before the chat appears.
