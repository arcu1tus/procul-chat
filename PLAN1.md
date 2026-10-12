# PLAN 1 — Frontend (Flutter) UX overhaul, regressions & branding

> **Audience:** the coding agent (or human) implementing this. Read `frontend/AGENTS.md` first — it is
> the authoritative conventions/gotchas for the client. The backend/API work this depends on is in
> **PLAN 2**; tests/docs/rollout in **PLAN 3**.
>
> **Standing rules (do not skip):** start a branch (`feat/frontend-ux`); commit, then **ASK** before
> pushing; keep `AGENTS.md` + `docs/` in sync in the same change; **short timeouts** (start ~15s, raise
> incrementally); keep `flutter analyze` clean and run `dart format lib test` before committing.

## 0. Baseline

| Command | Expected |
| --- | --- |
| `cd frontend && flutter analyze` | clean |
| `cd frontend && flutter test` | green |
| `cd backend && dotnet test Procul.slnx` | green |

Fix any red regression before starting.

## 0.1 The regressions in the screenshots (fix these first)

> The four regression screenshots are attached to the session that implements **PLAN 1**. Open them
> before starting; they are the source of truth for these bugs.

- **Screenshot 1** — the sidebar's *refresh* button "doesn't do anything" (no visible effect/feedback).
- **Screenshot 2** — "the top app bar renders correctly until the content loads, then turns into a
  mess": on a narrow screen the chat `AppBar`'s trailing actions overflow and paint over each other /
  the title.
- **Screenshot 3** — the conversation tile's **triple-dot menu does nothing**, and the sidebar footer
  (Usage/Models/Settings) sits **too close to the Android system navigation bar**.
- **Screenshot 4** — the chat header's **triple-dot menu does nothing as well**, and the app-bar title wraps
  **one character per line** ("why is the sky blue?" stacked vertically) when space is tight — which
  stretches the **whole app bar to the height of the screen** (shadcn's `AppBar` uses `IntrinsicHeight`,
  so an N-line title makes an N-line-tall bar).

**Root cause already identified (Screenshots 2 & 4):** shadcn's `AppBar` lays `leading` and `trailing`
out as *intrinsic-width* `Row`s and only gives the middle (title) column the remaining `Flexible`
space. When the trailing list is wider than the bar it overflows and paints over the title, and the
title's remaining width can collapse to ~0 (hence one char per line). The title is also rendered
without `maxLines`/`overflow`. **Fix = collapse trailing on narrow widths + give the title
`maxLines: 1, overflow: ellipsis`.**

---

## 1. Feature groups

### P1 — Narrow-screen app bar: stop the overflow "mess" and the full-height stretch (Screenshots 2 & 4)

**Goal:** the chat header never overflows, never paints over itself, and never grows to the full height of
the screen; the title ellipsizes on one line.

**Files:** `lib/src/chat_screen.dart` (`AppBar`), `lib/src/home_shell.dart`, `lib/src/widgets/icon_action.dart`.

**Approach**
- Title: `Text(..., maxLines: 1, overflow: TextOverflow.ellipsis)`.
- Collapse the trailing actions on narrow widths into a **single overflow `IconAction(ellipsis)`** whose
  `showDropdown` menu holds *Refresh*, *Model…*, *Usage…*, *Rename*, *Delete*. Reuse the existing
  `compactModelPicker` / `compactActions` flags; add a compact notion for the usage chip + refresh, or
  derive compact from `MediaQuery.sizeOf(context).width`.
- Wide layout unchanged (model chip + usage chip + refresh + rename + delete).
- Audit `AppBar.trailing` in `usage_screen.dart` / `models_screen.dart` so none can overflow at
  320–360 px.

**Acceptance:** at 320×640 and 360×800 with a long title and ≥2 models, `tester.takeException() == null`,
the title is exactly 1 line, and every action is reachable from the overflow menu.

---

### P2 — Triple-dot menus actually open (Screenshots 3 & 4)

**Goal:** the conversation-tile `…` and the chat-header `…` open their menus (Rename/Delete, etc.).

**Files:** `lib/src/conversation_sidebar.dart` (`_ConversationTileState._showMenu`),
`lib/src/chat_screen.dart` (`_showChatMenu`).

**Approach (investigate → fix)**
1. Reproduce with a widget test that taps `…` and asserts the menu items appear.
2. Candidate causes to rule out:
   - The tile's `…` is nested inside the tile's `Clickable(onPressed: onSelect)`; the parent may win the
     gesture arena so the icon's `onPressed` never fires. Fix by **not** nesting the trigger in the
     parent tap target (sibling in the tile `Row`, or a `GestureDetector` on the body only).
   - `showDropdown` anchored to a zero-size/offscreen render object — pass a `Builder` context right
     around the trigger, or an explicit `position`/`anchorAlignment`.
   - The overlay dismissing on the same pointer event — use the `MenuButton`/`autoClose` pattern the
     model picker already uses, or tune `dismissBackdropFocus`/`consumeOutsideTaps`.
3. Prefer a real anchored control (shadcn `MenuButton`/`MenuAnchor`) so anchoring + dismissal are
   framework-handled.

**Acceptance:** tapping `…` on a tile and on the header opens the expected menu; Rename/Delete run the
existing dialogs; a widget test asserts the items are present and tappable.

---

### P3 — Sidebar refresh gives feedback (Screenshot 1)

**Files:** `lib/src/conversation_sidebar.dart` (`_Header`), `lib/src/chat_controller.dart`.

**Approach**
- Show a **spinner** in the refresh `IconAction` while a refresh is in flight (add an `isRefreshing`
  flag to `ChatController`; don't reuse `isLoadingConversations`, which drives the full skeleton).
- `refreshConversations()` sets the flag, notifies, clears in `finally`, and surfaces failures via the
  existing error toast. The chat app-bar `refreshAll` gets the same treatment.

**Acceptance:** tapping refresh swaps the icon for a spinner for the fetch duration and the list
reflects server state afterwards.

---

### P4 — Sidebar footer respects the system navigation bar (Screenshot 3)

**Files:** `lib/src/conversation_sidebar.dart`, `lib/src/home_shell.dart`, `lib/src/chat_screen.dart` (`_Composer`).

**Approach**
- Add explicit bottom insets: `EdgeInsets.only(bottom: 8 + MediaQuery.viewPaddingOf(context).bottom)` on
  the footer; verify the sidebar's `SafeArea` really receives the inset (the narrow panel is a
  `Positioned` inside a `Stack`, not inside a `Scaffold`).
- The composer's `SafeArea(top: false)` must honor `viewInsets.bottom` (keyboard) and
  `viewPadding.bottom`.
- On Android (edge-to-edge by default in recent Flutter), opt into insets rather than drawing under the
  nav bar; check `android/app/src/main/res/values*/styles.xml` + `MainActivity`.

**Acceptance:** on a gesture-nav device the footer and send button are clear of the system bar; a widget
test with a synthetic `viewPadding.bottom` asserts the inset.

> **Note:** if **P4b** ships (the footer moves to a top tab row), the bottom of the sidebar becomes the
> scrollable chat list, which still needs the normal `SafeArea` bottom inset — verify it there instead.

---

### P4b — Move Usage / Models / Settings to a top "tab" row above the chats

**Idea (from the user):** instead of a footer row at the bottom of the sidebar, put the three actions in a
tab-like row just below the brand header and **above** the conversation list, with a **divider** separating
them from the chats.

**Files:** `lib/src/conversation_sidebar.dart` (`_Header`, the footer `Row`, `_ConversationList`),
`lib/src/home_shell.dart` (wiring unchanged).

**Approach**
- Remove the bottom `Divider` + footer `Row` (the three `_FooterButton`s) and the `Expanded(_ConversationList)`
  that sat above it.
- New sidebar column: `_Header` (brand + refresh/close) → a **tab row** of three buttons (Usage / Models /
  Settings) → a `Divider()` → the conversation list (`Expanded`) → bottom `SafeArea`.
- Style the row as tabs: three equal-width `GhostButton`s (a `SelectedButton` when its overlay is open) with
  icon + label; the one whose screen is currently shown reads as "selected". Keep the existing callbacks
  (`onOpenUsage` / `onOpenModels` / the Settings dialog) so behaviour is unchanged.
- This **removes the footer**, so P4's footer-vs-nav-bar problem goes away; the sidebar bottom is now the
  scrollable chat list (normal `SafeArea` bottom inset).
- Confirm/update the "three buttons are tight" widget-test invariant documented in `frontend/AGENTS.md` for
  the new layout.

**Acceptance:** the three actions render as a tab row above the list with a divider below them; tapping one
opens the same Usage/Models screen or Settings dialog as before; the active one is highlighted; no overflow
at 300 px (wide) or phone widths; the bottom of the sidebar clears the system nav bar.

**Tests:** update `test/home_shell_test.dart` / `test/responsive_layout_test.dart` to assert the tab row is
above the list, the divider is present, and the old footer is gone.

---

### P5 — User-message actions: triple-dot menu with Edit

**Goal:** editing is reachable on **every user message** (touch included) via a `…` menu, not only on
desktop hover.

**Files:** `lib/src/chat_screen.dart` (`_MessageBubble`), `lib/src/chat_controller.dart` (edit flow exists),
`lib/src/widgets/icon_action.dart`.

**Approach**
- Replace the hover-only Edit `IconAction` with a **persistent** `IconAction(ellipsis)` on each user
  bubble. Menu: **Edit**, **Copy** (clipboard). No per-message delete (no endpoint).
- Tapping **Edit** calls the existing `_beginEdit(message)` → composer banner + "Save changes"; verify the
  whole round-trip (it exists but was unreachable on touch).
- Hidden/disabled while `chat.isStreaming` or already editing.

**Acceptance:** a widget test taps a user bubble `…`, sees *Edit*, taps it, and the composer shows the
"Editing message" banner with the text prefilled; submitting calls the edit endpoint.

---

### P6 — Attachment sources: Camera / Gallery / Files (native)

**Goal:** the attachment button opens a menu with **Camera**, **Gallery**, and **Files**; the camera is
the OS's native camera UI; the camera entry is **hidden where the platform has no native camera control**.

**Library decision (researched):** use **`image_picker`** (Flutter team, federated) plus the existing
`file_picker`.
- `image_picker` hands off to the OS: Android camera intent + Android Photo Picker; iOS
  `UIImagePickerController` + `PHPicker`. This is the "native camera taking option" you want (it does
  **not** embed a custom preview).
- It exposes `supportsImageSource(ImageSource.camera)` for a **runtime** check, so Camera is shown only
  where supported (desktop/web have no native camera UI → hidden).
- Rejected third-party all-in-ones (`flutter_unified_attachment_picker`, `image_picker_master`,
  `universal_file_picker`): lower maintenance trust; `file_picker` already covers Files.

**Files:** `lib/src/attachments.dart`, `lib/src/chat_screen.dart`, `lib/src/chat_controller.dart`,
`test/support/fake_attachment_picker.dart`, `pubspec.yaml`, platform config.

**Approach**
- **Availability helper** (pure + testable): `AttachmentSources.available()` returns
  `{camera?, gallery, files}` — Camera iff
  `ImagePickerPlatform.instance.supportsImageSource(ImageSource.camera)` (fallback:
  `defaultTargetPlatform` is Android/iOS); Gallery and Files always.
- **Dropdown UI:** the paperclip opens a `showDropdown`/`DropdownMenu` of `MenuButton`s built from
  `AttachmentSources.available()` **and** the active model's capabilities (via `_activeCapabilities()`).
  Audio/PDF entries only when the model supports them; `text/*` always; video never.
- **Seam:** extend `AttachmentPicker`:
  - `Future<List<PickedAttachment>> pickFromGallery({bool allowMultiple, List<String>? allowedExtensions})`
    (`ImagePicker().pickMultiImage()` / `pickImage(source: gallery)`; read bytes from `XFile`).
  - `Future<PickedAttachment?> pickFromCamera()` (`ImagePicker().pickImage(source: camera)`).
  - `Future<List<PickedAttachment>> pickFiles({bool allowMultiple, List<String>? allowedExtensions})`
    (existing `file_picker`; add `allowMultiple`).
  - Update `FakeAttachmentPicker` to record each call and return canned results.
- **Multi-upload:** add `ChatController.uploadAttachments(List<PickedAttachment>, {capabilities})` that
  uploads each, keeps going on per-file failure, and appends to `pendingAttachments` (existing
  `uploadAttachment` stays as the single-item core).
- **Platform config:** iOS `Info.plist` → `NSCameraUsageDescription` and `NSPhotoLibraryUsageDescription`.
  Android: the camera intent normally needs no `CAMERA` permission (verify on device; add
  `<uses-permission android:name="android.permission.CAMERA"/>` only if required). Android 13+ photo
  picker is automatic.
- Keep the backend re-validation (`?model=<active>` on upload).

**Acceptance:** the paperclip opens Camera (mobile only) / Gallery / Files; Gallery + Files multi-select;
camera captures via the native UI and uploads; the menu never offers a type the model can't read.

**Tests:** `test/attachment_upload_test.dart` (sources + multi + camera), `test/chat_attachments_test.dart`.

**Retention UX (pairs with PLAN 2 §B3):** when the backend has purged an attachment's bytes (its retention
window elapsed), `GET /v1/attachments/{id}` returns `404`; the existing `_AttachmentImage` already falls
back to a chip on error. Improve that fallback to a clear **"File expired"** chip (icon + name + a muted
"no longer stored" note) instead of a generic file chip, and add a widget test for it.

---

### P7 — Chat scroll: infinite scroll up + refresh at the bottom (pull the other way)

**Goal (your words):** refresh the chat **without scrolling to the top** — pull in the *other*
direction (up) at the bottom. Also: scrolling up loads older messages.

**Files:** `lib/src/chat_screen.dart` (`_body`, `_trackPin`, `_onChanged`), `lib/src/chat_controller.dart`,
`lib/src/chat_api.dart` (`fetchMessages`).

**Approach**
- **Reversed list.** Switch the message `ListView.builder` to `reverse: true` and flip the index
  (`chat.messages[chat.messages.length - 1 - index]`). Then offset `0` is the newest message, pinning
  during streaming is automatic, and the user is never yanked while reading. Keep the entrance-animation
  set working with the flipped index.
- **Bottom pull-to-refresh.** Wrap the reversed list in `RefreshTrigger(reverse: true, onRefresh: …)` so
  the pull happens at the **bottom** (shadcn `RefreshTrigger` supports `reverse` + `direction` and
  triggers on `extentAfter == 0`). Keep `onRefresh: chat.isStreaming ? null : …` so a pull can't clobber a
  live stream. *(Verify empirically: `RefreshTrigger.reverse` and `ListView.reverse` are two different
  coordinate flips. If the combination misbehaves, ship a tiny custom bottom pull indicator or keep the
  explicit refresh button as the guaranteed path — document whichever ships.)*
- **Load older (infinite scroll up).** Add `hasMoreHistory`, `isLoadingOlder`, and the oldest loaded id to
  `ChatController`; `loadOlderMessages()` calls
  `api.fetchMessages(id, afterMessageId: oldestId, limit: 100)` — the backend's `afterMessageId` cursor
  already means "older than this" (keyset `CreatedAt < cursor`), so **no API change** — and **prepends**.
  Trigger when `position.pixels > maxScrollExtent - 300 && hasMoreHistory && !isLoadingOlder`. Set
  `hasMoreHistory` in `_openConversation` from "page was full". Show a small "Loading older messages…"
  row at the top. This closes the documented "history paging is shallow" limitation — update `AGENTS.md`.
- **Optional polish:** a "jump to latest" pill when scrolled away (`offset > ~80`) → animate back to `0`.
- Keep the empty state scrollable (`AlwaysScrollableScrollPhysics`).

**Acceptance:** a pull at the bottom refreshes (no need to reach the top); scrolling to the top loads
older messages with no duplication or scroll jump; streaming never fights the user.

**Tests:** `test/pull_to_refresh_test.dart` (extend; `RefreshTriggerState.refresh()` is public for
deterministic driving) + new `test/chat_pagination_test.dart`.

---

### P8 — "Better animations, more modern UI" (tasteful, bounded)

**Files:** `lib/src/chat_screen.dart`, `lib/src/conversation_sidebar.dart`, `lib/src/home_shell.dart`,
`lib/src/widgets/skeleton.dart`, `lib/src/app_theme.dart`.

**Approach (keep the existing design language: shadcn, Inter/Coiny, 120–220 ms `easeOut`)**
- Bubbles: slightly larger radius, softer borders, subtle hover lift; comfortable markdown line-height.
- Entrance: a *capped* stagger on history load; keep it one-shot and suppressed for whole-history loads.
- Composer: gentle focus-ring animation; send button scale/fade as it enables.
- Streaming: keep `_ShimmerText`; consider a soft per-chunk fade (avoid per-token layout churn).
- **Respect `MediaQuery.disableAnimations` / `accessibleNavigation`** — skip non-essential motion when set
  (a real requirement, not optional).
- No new packages.

**Acceptance:** `flutter analyze` clean; no jank on long lists; reduced-motion users get a static UI;
existing motion tests pass.

---

### P9 — Accent color `#a832a0`

**Files:** `lib/src/app_theme.dart`, `web/manifest.json`, `web/index.html`, Android `values*/styles.xml` +
`drawable*/launch_background.xml`, iOS/macOS launch assets (if branded), `linux/runner/my_application.cc`.

**Approach**
- `_lightAccent = _darkAccent = const Color(0xFFA832A0)`; set `ring` to it; tune `primaryForeground` only
  for contrast (white in light; verify dark contrast and use white or a very light tint there). The
  `ShadcnMaterialBridge` seeds Material from `colors.primary`, so markdown follows.
- Update the web PWA `background_color`/`theme_color` and splash colors.
- Sweep for hard-coded teal (`0xFF0D9488`, `0xFF2DD4BF`, `0xFF042F2E`) and replace.

**Open question:** if dark-mode contrast is poor, allow a lighter tint (e.g. `#C86BC2`) for dark primary;
default honors `#a832a0` in both modes with a tuned foreground.

---

### P10 — App name "Procul Chat" (not `procul_chat_flutter`)

**Exact strings**
- **Android:** `android/app/src/main/AndroidManifest.xml` → `android:label="Procul Chat"`.
- **iOS:** `ios/Runner/Info.plist` → `CFBundleDisplayName` = `Procul Chat`, `CFBundleName` = `Procul Chat`.
- **macOS:** `macos/Runner/Info.plist` → add `CFBundleDisplayName` = `Procul Chat`; set `PRODUCT_NAME` in
  `macos/Runner.xcodeproj` (bundle id unchanged).
- **Windows:** `windows/runner/main.cpp` window title `L"Procul Chat"`; `windows/runner/Runner.rc` product
  strings.
- **Linux:** `linux/runner/my_application.cc` window/header title `"Procul Chat"`; ship a `.desktop` with
  `Name=Procul Chat` + `Icon=procul-chat`.
- **Web:** `web/manifest.json` `name`/`short_name`; `web/index.html` `<title>`,
  `apple-mobile-web-app-title`, description.
- **Dart:** `MaterialShadcnApp(title: 'Procul Chat')` (already correct).
- **Decision (confirmed):** **keep** the pubspec package name `procul_chat_flutter` (renaming it would
  churn every `package:` import in `test/`); fix display names only.

---

### P11 — App icon: prepare + document exactly where icons go

**Deliverable ("prepare" part)**
1. Add `flutter_launcher_icons` to `dev_dependencies` + a `flutter_launcher_icons:` block. Source image:
   **`frontend/assets/icon/icon.png`, 1024×1024 px, opaque PNG**; optional Android adaptive foreground +
   `adaptive_icon_background` `#a832a0`.
2. Run `dart run flutter_launcher_icons` after the user drops in the source — regenerates every target.
3. Add an **"App icon"** section to `docs/flutter-builds.md` with the table below.

**Where the icons live (current generated layout — verified in this repo)**

| Platform | Path(s) | Size(s) |
| --- | --- | --- |
| Android (legacy) | `android/app/src/main/res/mipmap-{mdpi,hdpi,xhdpi,xxhdpi,xxxhdpi}/ic_launcher.png` | 48, 72, 96, 144, 192 |
| Android (adaptive, if configured) | `mipmap-anydpi-v26/ic_launcher.xml` + foreground/background drawables | `108dp` |
| iOS | `ios/Runner/Assets.xcassets/AppIcon.appiconset/Icon-App-*.png` + `Contents.json` | 20/29/40/60/76/83.5 pt @1x–3x + 1024 |
| macOS | `macos/Runner/Assets.xcassets/AppIcon.appiconset/app_icon_{16,32,64,128,256,512,1024}.png` | 16…1024 |
| Windows | `windows/runner/resources/app_icon.ico` | multi-size ICO (16…256) |
| Web | `web/icons/Icon-192.png`, `Icon-512.png`, `Icon-maskable-192.png`, `Icon-maskable-512.png`, `web/favicon.png` | 192/512 |
| Linux | no icon file by convention; ship a `.desktop` + themed icon (`hicolor/<size>/apps/procul-chat.png`) | 16…512 |

**Acceptance:** with only `assets/icon/icon.png` present, `dart run flutter_launcher_icons` produces all
targets; `docs/flutter-builds.md` documents the table; the user is told to commit the generated icons.

---

### P12 — Per-response profile: model + time + tokens

**Goal:** tapping an assistant response shows **that response's** model, timestamp, and tokens — not the
conversation total.

**Files (client):** `lib/src/models.dart` (`ChatMessage` gains `model`, `usage`),
`lib/src/chat_stream_event.dart` + `lib/src/chat_api.dart` (`usage` event carries `model`; history carries
per-message `model`/`usage`), `lib/src/chat_controller.dart`, `lib/src/chat_screen.dart`.

**Backend dependency (PLAN 2 §B4):** `TurnUsage.MessageId` + per-message `model`/`usage` in history.
Until it lands, show the **live** turn's model/time/tokens (from `UsageEvent` + `activeModel` + now).

**Approach**
- Make the assistant `_Avatar` (or a small info chip under the bubble) tappable → `showDropdown` popover
  with **Model**, **Time** (absolute + relative via `time_format.dart`), **Tokens**
  (input/output/cached/total via `formatTokenCount`). Reuse `_usageLabel` styling.
- Populate `createdAt` from history and at stream time; set `model`/`usage` from the `usage` event + history.
- Degrade gracefully ("—") when unknown.

**Tests:** `test/token_usage_test.dart`, `test/chat_usage_test.dart`.

---

### P13 — Cross-device consistency (client side)

**Goal:** two devices on the same backend stay "relatively in sync" and don't clobber each other.

**Files:** `lib/main.dart` (lifecycle observer), `lib/src/chat_controller.dart`, `lib/src/home_shell.dart`.

**Approach**
- **Refresh on resume/focus.** A `WidgetsBindingObserver` calls `chat.refreshAll()` on
  `AppLifecycleState.resumed` (and web window focus). Guarded so it never clobbers a live stream
  (`reloadActiveConversation` is already a no-op while streaming) or an in-progress edit.
- **Light periodic sync.** While idle, poll list + active history every ~20–30s (cheap, cancellable).
- **Conflict handling.** On `409` (PLAN 2 §B5) from rename/edit/model-change, resync and show
  "This chat changed on another device — refreshed".

**Tests:** controller test simulating a resume + a `409` (resync + toast).

---

## 2. New/changed dependencies

| Package | Why | Notes |
| --- | --- | --- |
| `image_picker` | native Camera + Gallery | Camera hidden where `supportsImageSource(camera)` is false |
| `image_picker_platform_interface` | call `supportsImageSource(...)` | version-locked by `image_picker` (only if not re-exported) |
| `flutter_launcher_icons` (dev) | generate all platform icons from one PNG | see P11 |

Already present: shadcn `RefreshTrigger`, `file_picker`, `gpt_markdown`, `fl_chart`.

## 3. Open questions (defaults apply if unanswered)

1. **P9 dark-mode accent:** exact `#a832a0` in both modes (default) vs a lighter tint for dark contrast.
2. **P7 bottom-refresh fallback:** if `RefreshTrigger(reverse:true)` misbehaves with a reversed list,
   ship a custom bottom indicator or keep the refresh button as the primary path.
3. **P13 periodic poll:** always-on ~30s (default) vs opt-in via Settings.
