# AGENTS.md — Procul chat frontend (Flutter)

> **Keep this file up to date.** If you change the structure, conventions, commands, or
> gotchas described here, update this file in the same change. A stale AGENTS.md is worse
> than none. When in doubt, add a short note rather than leaving it wrong.

## What this is

The Flutter chat client ("Procul") for the Procul backend. It supports **multiple
conversations** (list, switch, rename, delete), streams assistant replies over SSE, shows
tool activity, renders assistant Markdown, and has a persisted **settings** dialog (theme:
light / dark / system, dark default). It also tracks **token usage**: a per-conversation
counter chip in the chat app bar and a **Usage** dashboard reachable from the sidebar. The
backend can serve **multiple models**, so the chat app bar carries a per-conversation **model
picker** and the sidebar's **Models** entry opens a catalog of every configured model (name,
description, capability badges, live health). It
talks to the backend's versioned
`/v1/conversations` API, which is **password-protected**: the app signs in with a shared
password, keeps the returned session token in secure storage, and can save and switch between
**multiple server profiles**.

- **Flutter** (Dart `^3.13.5`).
- **UI:** [`shadcn_flutter`](https://pub.dev/packages/shadcn_flutter) (`^0.0.55`) — the app
  is built on shadcn components and the **New York** theme, not Material.
  `shadcn_flutter_material` provides a Material interop layer (see gotchas).
- **Fonts:** [`google_fonts`](https://pub.dev/packages/google_fonts) (`^9.0.0`) — **Inter**
  is the UI face everywhere, **Coiny** is used for a couple of display accents (the sidebar
  "Procul" wordmark and the empty-state heading). Inline code / code blocks stay on the
  bundled **GeistMono**.
- **Markdown:** `gpt_markdown` (`^1.3.4`) renders assistant replies (code, lists, bold).
- **Charts:** [`fl_chart`](https://pub.dev/packages/fl_chart) (`^1.2.0`) — the Usage
  dashboard's daily bar chart (the only charting dependency).
- **HTTP:** `package:http` (manual SSE parsing; no SSE package).
- **Persistence:** `package:shared_preferences` — server profiles (without tokens), the active
  server id, the active conversation id and settings.
- **Secure storage:** `package:flutter_secure_storage` — per-profile session tokens only.
- **State:** plain `ChangeNotifier`s surfaced with `ListenableBuilder`. No
  provider/riverpod/bloc.

The backend lives in `../backend` and its contract is documented in `../backend/AGENTS.md`.

## Layout

```
frontend/
  lib/
    main.dart                     # entrypoint: preloads settings + auth + fonts; routes between
                                  #   ConnectScreen (signed out) and the keyed AuthenticatedShell
    src/
      config.dart                 # apiBaseUrl (PROCUL_API_BASE dart-define)
      models.dart                 # domain types: Conversation (incl. model), ChatMessage, ToolCall,
                                  #   MessageRole, TokenUsage + formatTokenCount;
                                  #   ChatModel/ModelCapabilities/ModelHealth + modality/status enums
      mcp_status.dart             # McpServerStatus: read-only MCP server status DTO
      mcp_status_controller.dart  # McpStatusController: MCP status for the Settings section
      model_catalog_controller.dart # ModelCatalogController: configured models + default + health
                                  #   checks; owned by the shell (picker + Models screen share it)
      chat_stream_event.dart      # SSE ChatStreamEvent hierarchy (Created/Token/Usage/ToolCall/...)
      chat_api.dart               # ChatApi: authenticated REST + SSE client (Bearer token);
                                  #   conversations, models (+ health checks), usage, MCP status
      auth_api.dart               # AuthApi: unauthenticated POST /v1/auth/session
      auth_controller.dart        # AuthController: server profiles + active session
      server_profile.dart         # ServerProfile + URL parsing/normalization helpers
      server_store.dart           # ServerStore: profile list + active id (shared_preferences)
      credential_store.dart       # CredentialStore: per-profile token (flutter_secure_storage)
      connect_screen.dart         # signed-out screen: saved servers + add-server form
      server_form.dart            # shared add-server form + add/remove dialogs
      conversation_store.dart     # ConversationStore: active conversation id (shared_preferences)
      settings_store.dart         # SettingsStore: persisted preferences (shared_preferences)
      settings_controller.dart    # SettingsController: theme mode (dark default)
      chat_controller.dart        # ChatController: conversation list + active buffer + turn logic
                                  #   + activeUsage (per-conversation) / lastTurnUsage
      usage.dart                  # UsageSummary/UsageDay/UsageModel/UsageBreakdown DTOs
      usage_controller.dart       # UsageController: dashboard summary + range + loading/error
      usage_screen.dart           # Usage dashboard: lifetime cards, fl_chart bars, per-model list
      models_screen.dart          # Models catalog: name/description/capability badges/health,
                                  #   per-model + check-all probes, refresh
      app_theme.dart              # proculLightTheme / proculDarkTheme (shadcn ThemeData, teal + Inter)
                                  #   + ShadcnMaterialBridge (flutter/material theme for markdown)
      home_shell.dart             # responsive shell: sidebar (wide) / slide-in panel (narrow);
                                  #   owns the ModelCatalogController; overlays UsageScreen/ModelsScreen
      conversation_sidebar.dart   # conversation list, new chat, usage + models + settings footer
      conversation_actions.dart   # rename + delete dialogs (shared by sidebar and header)
      settings_dialog.dart        # settings dialog (theme selector + server management)
      chat_screen.dart            # chat pane: header (+ model picker + usage chip), message list,
                                  #   composer; streaming shimmer over assistant Markdown
      widgets/
        skeleton.dart             # Shimmer + Skeleton loading placeholders
        icon_action.dart          # IconAction: ghost icon button + tooltip + a11y label
        model_badges.dart         # CapabilityBadge(s) + ModelHealthDot (shared by picker & Models)
  test/                           # controller, API, auth, settings, and widget tests
  test/support/                   # shared test doubles (FakeConversationStore, FakeCredentialStore,
                                  #   FakeServerStore) + model_fixtures.dart (GET /v1/models payloads)
  test/flutter_test_config.dart   # disables google_fonts runtime fetching for all tests
  linux/ android/ ios/ ...        # platform shells (generated)
  pubspec.yaml
```

## Build / run / test

The backend must already be running (dev: `http://localhost:5010`).

```bash
cd frontend
flutter pub get
flutter analyze                    # must stay clean
flutter test                       # unit + widget tests (no backend needed)
dart format lib test               # before committing
flutter run -d linux              # native Linux desktop
flutter run -d chrome             # web (backend allows any origin in dev — see gotchas)
flutter build linux --debug
```

Base URL defaults to `http://localhost:5010`; override without editing code:

```bash
flutter run -d linux --dart-define=PROCUL_API_BASE=http://localhost:5010
```

For **release builds** the API base URL must be the deployed backend's public origin (there is
no default that works in production), and the backend must allow that client's origin via its
`CORS_ALLOWED_ORIGINS` setting:

```bash
flutter build web --release --dart-define=PROCUL_API_BASE=https://api.example.com
```

## Backend contract (v1) as consumed here

**Authentication.** Every `/v1/conversations` request carries `Authorization: Bearer <token>`.
The token comes from `POST {baseUrl}/v1/auth/session` with body `{"password":"…"}` →
`200 {"token":"…","expiresAt":"…"}` or `401`. A `401` on any request raises
`UnauthorizedException` and fires `ChatApi.onUnauthorized` once, which the app wires to
`AuthController.logout()` — so an expired token (or a server-side password change) drops the
user back to the Connect screen. `GET {baseUrl}/health` is public.

Base: `{baseUrl}/v1/conversations`, where `baseUrl` is the active profile's saved URL.

| Action | Request | Response |
| --- | --- | --- |
| List chats | `GET /` | JSON `{"conversations":[...]}`, newest activity first |
| Start chat | `POST /` body `{"initialMessage":"...","model":"<slug>"?}` | SSE |
| Send message | `POST /{id}/messages` body `{"text":"..."}` | SSE |
| History | `GET /{id}/messages?limit=1..100&afterMessageId=<guid>` | JSON |
| Rename | `PATCH /{id}` body `{"title":"..."}` | JSON `{"conversation":{...}}` |
| Set model | `PUT /{id}/model` body `{"model":"<slug>"}` | JSON `{"conversation":{...}}` |
| Delete | `DELETE /{id}` | `204` (404 treated as success) |
| Models | `GET /v1/models` | JSON `{defaultModel, models:[{slug,name,description,provider,isDefault,capabilities:{input[],output[]},health:{status,lastCheckedAt,latencyMs,lastError,lastUsedAt,source}}]}` |
| Check models | `POST /v1/models/check` · `POST /v1/models/{slug}/check` | JSON (catalog / one model); slugs may contain `/` |
| MCP status | `GET /v1/mcp/servers` | JSON `{"servers":[{"name","type","url","connected","toolCount","tools","lastError","lastConnectedAt"}]}` |
| Conversation usage | `GET /v1/usage/conversations/{id}` | JSON totals `{inputTokens,outputTokens,cachedInputTokens,totalTokens,turns}` |
| Usage summary | `GET /v1/usage?days=30` | JSON `{lifetime, days:[{date,…}], models:[{model,…}]}` |

**SSE wire format.** There is **no `event:` field**; each event is a `data: <json>` line
followed by a blank line, and the kind is a `type` discriminator *inside* the JSON under
`value`:

```
data: {"value":{"conversation":{"id":"…","title":"…","createdAt":"…","updatedAt":"…"},"type":"created"}}
data: {"value":{"message":"received","type":"acknowledge"}}
data: {"value":{"callId":"…","name":"get_current_time","arguments":"{\"utcOffsetMinutes\":120}","type":"toolCall"}}
data: {"value":{"callId":"…","result":"2026-10-11T15:38:44+02:00","error":null,"type":"toolResult"}}
data: {"value":{"content":"Hello","type":"token"}}
data: {"value":{"inputTokens":10,"outputTokens":5,"cachedInputTokens":2,"totalTokens":17,"type":"usage"}}
data: {"value":{"error":"…","type":"error"}}
data: {"value":{"type":"done"}}
data: {"value":{"conversationId":"…","title":"France's capital","type":"title"}}
```

`created` is only emitted by `POST /`; `POST /{id}/messages` emits
`acknowledge` → (`toolCall` → `toolResult`)* → `token`* → `usage`? → (`error` | `done`).
`usage` (the reply's summed token counts) is emitted just before `done` **only when usage was
seen**; `title` is only
emitted by `POST /`, **after** `done` — the model-generated title arrives a moment after the
reply, so the client must treat `done` (not stream close) as the end of a turn. Tool events
only appear when the model actually calls a tool, and correlate via `callId` (`arguments` is a
JSON object string; `result` is the tool output and `error` its failure message). Parse
accordingly in `ChatApi._decodeEvent`.

**JSON is camelCase** (`initialMessage`, `messageRole`, `createdAt`, `updatedAt`).

**`messageRole` is an integer**, not a string: `0=System, 1=User, 2=Assistant, 3=Tool`
(the C# enum ordinal). Map it in `models.dart` via `messageRoleFromValue`; unknown values
fall back to `user`.

**History is newest-first** (`ORDER BY CreatedAt DESC, Id DESC`) and keyset-paginated with
`afterMessageId`. `ChatApi.fetchMessages` reverses the page to oldest-first before it
reaches the buffer.

## Conventions & patterns

- **One `ChatController` owns both the list and the active conversation.** It holds
  `conversations`, `activeConversationId`, and `messages`. `init()` loads the list and reopens
  the persisted id; `selectConversation` fetches a history once; replies are appended from the
  SSE stream (never re-fetched). List mutations (`renameConversation`, `deleteConversation`)
  update the local list optimistically/after the call so the sidebar stays in sync.
- **`done` ends the turn.** `ChatController.send` sets `isStreaming = false` on `DoneEvent`
  (not in `finally`), so the composer re-enables while the trailing `title` event is still in
  flight. The `title` event then updates the conversation's title in the list.
- **`ChatMessage.text` is mutable** on purpose: an empty assistant bubble is inserted up
  front and filled in token-by-token as `TokenEvent`s arrive.
- **Tool activity lives on the assistant message.** `ToolCallEvent`/`ToolResultEvent` are
  folded into the streaming assistant `ChatMessage.toolCalls` (matched by `callId`), not added
  as separate buffer entries. Tool calls are not persisted, so they vanish on reload.
- **Token usage is two-level.** `ChatController.activeUsage` is the active conversation's
  cumulative total: seeded from `GET /v1/usage/conversations/{id}` when a conversation is
  opened, then incremented by each turn's `UsageEvent` so switching conversations needs no
  refetch. `lastTurnUsage` is just the most recent reply; both reset in `newChat()` /
  `deleteConversation`. The app-bar `_UsageChip` renders only when `activeUsage.hasTokens` and
  opens a `showDropdown` popover (`MenuLabel` rows + `MenuDivider`) with the
  input/output/cached/total breakdown.
- **The Usage dashboard is its own controller + screen.** `UsageController` mirrors
  `McpStatusController` and is owned by `UsageScreen`: it holds the `UsageSummary`, the
  selected range (`7/30/90/365`, default `30`; `365` is the "all" view, the backend caps a
  window at 366), plus `isLoading`/`error`. `UsageScreen` shows lifetime cards, a `fl_chart`
  bar chart with a Total/Input/Output metric toggle, a per-model breakdown list, and
  pull-to-refresh via `RefreshTrigger` **plus** an explicit `IconAction`. It is opened from the
  sidebar footer's **Usage** button beside Settings; `HomeShell` overlays it on top of the
  still-mounted chat so the chat's scroll position and buffer survive.
- **The model catalog is one controller owned by the shell.** `ModelCatalogController` (mirrors
  `McpStatusController`) holds `models`, `defaultModel` (derived from the `isDefault` entry),
  `isLoading`/`error`, and the check state (`checkingSlug`/`isCheckingAll`); `check(slug)` /
  `checkAll()` probe then `refresh()`. `HomeShell` creates it (from `chat.api`), `load()`s it once,
  and **mirrors its default into the controller** via `ChatController.setDefaultModel` so a
  brand-new chat can fall back to it. Both the app-bar picker and the Models screen read this one
  instance. The catalog is *not* re-created per screen (unlike `UsageController`, which
  `UsageScreen` owns).
- **The model is per conversation, with a pending choice for new chats.**
  `Conversation.model` is nullable; `ChatController.activeModel` is the active conversation's
  model, else a pending choice (`_pendingModel`, set by picking a model with no conversation yet
  and **kept across `newChat()`** so the last explicit choice sticks), else `defaultModel`.
  `setModel(slug)` optimistically updates the conversation and `PUT`s `.../model`, rolling back on
  failure (like `renameConversation`); with no conversation it just records the pending choice.
  `send` passes the model only on `createConversation`.
- **The app-bar model picker** (`_ModelPicker` in `chat_screen.dart`) shows the active model's
  name (or slug), is **hidden when only one model is configured**, is **disabled while streaming**,
  and opens a `showDropdown`/`DropdownMenu` whose rows carry a health dot, capability badges and a
  check on the active model. On narrow screens `HomeShell` passes `compactModelPicker: true`, which
  collapses it to a single `IconAction` (the `showMenuButton` pattern).
- **The Models screen is a read-only catalog with on-demand checks.** `ModelsScreen` renders each
  model's name/description/capability badges/a `Default` pill and a health row (status dot, latency,
  last checked/used, last error), with a per-model **Check** and a **Check all**, plus refresh via
  `RefreshTrigger` + `IconAction`; loading shimmer / empty / error match `UsageScreen`. Health is
  advisory — an unhealthy model stays selectable. It is overlaid on the still-mounted chat like
  Usage, from the sidebar footer's **Models** entry (three compact `_FooterButton`s: Usage, Models,
  Settings).
- **Assistant text shimmers while streaming.** `_ShimmerText` (in `chat_screen.dart`) wraps the
  `GptMarkdown` in a `ShaderMask` (`BlendMode.srcIn`) with a sliding `LinearGradient`, active
  only while the reply streams. It owns its own `AnimationController`, so per-token rebuilds do
  not restart the sweep, and it removes the overlay once the reply completes.
- **Errors are user-facing strings** on `ChatController.error`; `ChatScreen` shows them as a
  shadcn toast. Streaming failures still leave the partial reply in the bubble.
- **Settings are a `ChangeNotifier` + `shared_preferences`.** `SettingsController.themeMode`
  defaults to `ThemeMode.dark`; `setThemeMode(ThemeMode)` persists light/dark/system and
  `isDark` is a derived getter. `main.dart` rebuilds `MaterialShadcnApp` from it, and
  **awaits `settings.init()` (plus `GoogleFonts.pendingFonts`) before `runApp`** so the
  stored theme and fonts are in place on the first frame (no startup flash).
- **Auth is a `ChangeNotifier` + two stores.** `AuthController` owns the saved `ServerProfile`
  list and the active session. Profiles (and the active id) persist in `shared_preferences`
  via `ServerStore`; **session tokens persist only in secure storage** via `CredentialStore`.
  `main.dart` builds the controller, awaits `init()`, and renders `ConnectScreen` when
  `auth.active == null`, else an `AuthenticatedShell` **keyed by the profile id** so switching
  servers disposes the old `ChatController`/`ChatApi` and starts clean. `logout()` clears the
  active token (keeping the profile); `removeProfile(id)` also drops the profile.
- **The "add server" form is one widget, used twice.** `ServerForm` (`server_form.dart`) is
  embedded on the Connect screen and wrapped in a modal by `showAddServerDialog`, which
  Settings also calls. It owns its own validation and inline error; the modal's Save action
  drives `ServerFormState.submit()` so there is a single implementation.
- **Composer keyboard.** On desktop **Enter sends** and **Shift+Enter inserts a newline**
  (`CallbackShortcuts` bound to `SingleActivator(enter)`; the shifted variant falls through
  to the field). The on-screen send button and `onSubmitted` are kept, so
  `TextInputAction.send` still submits.
- **Loading states are hand-rolled shimmer, not spinners.** `widgets/skeleton.dart` provides
  `Shimmer` (one `AnimationController` sweeping a gradient over its children) and `Skeleton`
  blocks. The conversation list and message history show shaped placeholders; an assistant
  bubble awaiting its first token shows pulsing dots (`_ThinkingDots`).
- **Motion is subtle and one-shot** (120–220 ms, `easeOut`): new messages fade + rise once
  (tracked per `ChatMessage` in `ChatScreen`, and suppressed for a whole history load), the
  narrow-screen scrim + panel are driven by one `AnimationController`, and conversation
  tiles/tool rows use `AnimatedContainer` / `AnimatedSwitcher`.
- **Icon-only buttons go through `IconAction`** (`widgets/icon_action.dart`) so every one has
  a tooltip and an accessible label.
- **Pull-to-refresh uses `RefreshTrigger` plus an explicit button.** The conversation list
  (`conversation_sidebar.dart`), the chat pane (`chat_screen.dart`) and the MCP section
  (`settings_dialog.dart`) each wrap their scrollable in `RefreshTrigger`; every one also has a
  refresh `IconAction`, because mouse-overscroll on desktop is less discoverable than a drag.
  Empty states are scrollable (`AlwaysScrollableScrollPhysics`) so the gesture still works with
  no content. The chat pane's `onRefresh` is **null while `chat.isStreaming`** so a pull cannot
  clobber a live stream. `ChatController.refreshAll()` (list + active history) backs the chat
  app-bar button; `reloadActiveConversation()` is a no-op when none is active or a reply is
  streaming.
- **MCP status is read-only and secret-free.** `McpStatusController` (owned by the Settings
  dialog's `_McpSection`) fetches `GET /v1/mcp/servers` through `ChatApi`, so it inherits the
  bearer header and the `401 → logout` path. `showSettingsDialog` takes the `ChatApi`
  (`chat.api` from the sidebar). The section renders name, transport badge, online dot, tool
  count and `lastError` only — never headers or tokens. The dialog is created fresh per open and
  the shell is keyed by profile id, so it always reflects the active backend.
- **All UI is shadcn_flutter.** Use shadcn components (`Scaffold` + `headers: [AppBar(...)]`,
  `PrimaryButton`/`OutlineButton`/`DestructiveButton`/`GhostButton`, `SelectedButton` (used
  for the segmented theme selector), `TextField`, `AlertDialog` via `showOverlay`,
  `DropdownMenu` via `showDropdown`, `showToast`, `Clickable`) and `LucideIcons`. There is no
  Material `ScaffoldMessenger`/`SnackBar` usage.
- **Text styles are extension getters**, e.g. `Text('x').muted.small`, `.semiBold.large`.

## Secure storage & platforms

Session tokens live in `flutter_secure_storage` (a per-profile key, `procul.session.<id>`).
There is **no fallback to `shared_preferences`** — if secure storage is unavailable the app
surfaces the error rather than downgrading the token to plaintext.

- **Linux** (the main target): needs `libsecret` at build *and* runtime, plus a running keyring
  (`gnome-keyring`, `kwallet` or another Secret Service implementation). Without one, reads
  and writes fail.
- **Web**: needs HTTPS or `localhost` (both fine); the implementation is experimental.
- **Windows**: needs the C++ ATL build tools.
- **macOS**: `SecureCredentialStore` passes `MacOsOptions(usesDataProtectionKeychain: false)`
  so the app does not need a provisioning profile / the data-protection-keychain entitlement.
- **Android/iOS**: use the platform Keystore/Keychain with no extra setup.

## Gotchas (learned the hard way)

- **`gpt_markdown` imports `package:flutter/material.dart`, so it needs a Material theme
  from *that* library.** `MaterialShadcnApp` (from `shadcn_flutter_material`) only installs
  the **`material_ui`** theme — a separate library — which `gpt_markdown` cannot see. Without
  a bridge the markdown falls back to Material's default *light* scheme, so in dark mode its
  code blocks turn near-white and its headings, rules and list markers use the wrong greys.
  `main.dart` therefore wraps the app in `ShadcnMaterialBridge` (in `app_theme.dart`), which
  derives a `package:flutter/material.dart` `ThemeData` from the ambient shadcn theme. Keep
  that bridge when changing the theme wiring; don't assume `MaterialShadcnApp` alone covers
  `gpt_markdown`.
- **`google_fonts` 9.x is built on `material_ui`, like shadcn.** `GoogleFonts.inter()` returns
  a `material_ui` `TextStyle` — the *same* type shadcn's `Typography.sans` wants (both are
  `package:flutter/widgets.dart` `TextStyle`), so the shadcn typography override is direct.
  But `GoogleFonts.interTextTheme()` returns a `material_ui.TextTheme`, which is a **different
  class** from the `package:flutter/material.dart` `TextTheme` the bridge builds, so it can't
  be assigned there. `ShadcnMaterialBridge` therefore applies the face with
  `base.textTheme.apply(fontFamily: interTextStyle.fontFamily, fontFamilyFallback: ...)`.
- **Tests must not fetch fonts.** `test/flutter_test_config.dart` sets
  `GoogleFonts.config.allowRuntimeFetching = false` before every test file; the themes then
  fall back to the platform face and no assertion depends on it. Keep that file if you add
  tests that build a theme.
- **shadcn `DrawerConfiguration` needs a `DrawerOverlay` ancestor** (`openRawDrawer` asserts
  `parentLayer != null`), which the default app does not provide. The narrow-screen sidebar is
  therefore a hand-rolled slide-in panel in `home_shell.dart`, not a shadcn drawer.
- **`ThemeMode` and `ColorScheme` are shadcn's**, re-exported by
  `package:shadcn_flutter/shadcn_flutter.dart` (not Material's). `ColorSchemes.darkZinc` etc.
  are **consts**, not functions (`ColorSchemes.darkZinc`, not `darkZinc()`).
- **`AppBar.leading`/`trailing` are non-nullable `List<Widget>`** — pass `const []`, not null.
- **`MenuButton.onPressed` is a `ContextedCallback`** (`void Function(BuildContext)`), not a
  `VoidCallback`.
- **`showOverlay(...)` returns an `OverlayCompleter`; use `.future`** to await the dialog's
  result. Pop with `Navigator.pop(context, value)`.
- **A `showDropdown` menu is an overlay entry, not a route — do not `Navigator.pop` it.**
  Popping from a `MenuButton.onPressed` pops the *app's* route (leaving a blank screen). Let the
  button's `autoClose` (the default) dismiss the menu and just run the action, as the model
  picker does.
- **Three sidebar footer buttons are tight.** They are `_FooterButton`s (compact-density, small
  `GhostButton`s with a leading icon and an ellipsizing label) inside `Expanded`s in a 300 px row;
  a widget test asserts `takeException()` is null so an overflow fails CI.
- **Backend input modalities include `pdf`, which maps to the `file` badge.** `ModelInputModality`
  has `text/image/file/audio/video`; `modelInputModalityFromValue` folds `pdf`/`file` into `file`
  and falls back to `text`. `ModelHealthStatus`/`modelInputModalityFromValue` also fall back, so a
  new backend value never crashes an older client.
- **Use `http.Client.send()` with a `http.Request`, not `client.post()`.** `post()` buffers
  the whole body into a `Response`; SSE needs the `StreamedResponse` from `send()`.
- **`Client.send()` only streams on real IO clients.** Fine on desktop/mobile; on web the
  browser `fetch`/XHR layer also buffers by default, so streaming may not be incremental
  there.
- **CORS.** Native Linux/desktop (the intended target) has no CORS. Running `-d chrome`
  sends requests from the Flutter web dev-server origin to the backend's origin, so the
  browser enforces CORS; the backend must approve the origin. It now does: in development the
  `ProculCors` policy allows any origin (the web dev-server port is ephemeral), and it can be
  pinned via the backend's `CORS_ALLOWED_ORIGINS` setting. In **production there is no
  wildcard** — a Flutter web build served from `https://app.example.com` only works if the
  backend's `CORS_ALLOWED_ORIGINS` names that exact origin. If Chrome still fails before
  streaming, the running backend predates that policy — rebuild/restart it.
- **Android: reach the backend with `adb reverse`, don't hardcode an IP.** The dev backend
  binds to `localhost:5010` only, so a phone can't reach it directly. Forward the port over
  ADB (works for USB *and* wireless ADB):

  ```bash
  adb reverse tcp:5010 tcp:5010     # phone's localhost:5010 -> host's localhost:5010
  flutter run -d <device-id>        # default base URL already works
  ```

  For an emulator without `adb reverse`, use
  `--dart-define=PROCUL_API_BASE=http://10.0.2.2:5010`; for a device on the same LAN, use
  the host's LAN IP (the backend must then bind to `0.0.0.0`, not just `localhost`).
- **Android blocks cleartext HTTP by default (API 28+).** `android/app/src/debug/AndroidManifest.xml`
  sets `android:usesCleartextTraffic="true"` so debug builds can talk to the plain-HTTP dev
  backend. Release builds keep the secure default. If you switch to HTTPS, remove it.
- **`flutter analyze` must stay clean.** `dart format lib test` before committing.
- **Tests must not touch the secure storage or `shared_preferences` channels.** Inject
  `FakeCredentialStore` / `FakeServerStore` (in `test/support/`) into `AuthController`, and
  `FakeConversationStore` into `ChatController`; `flutter_secure_storage` has no test double in
  the plugin, so a real `SecureCredentialStore` would fail on the platform channel.
- **The 401 path is the sign-out path.** `ChatApi` fires `onUnauthorized` once (wired to
  `auth.logout()`), and `main.dart` keys `AuthenticatedShell` by profile id. If you add a new
  authenticated call, route it through `ChatApi` so it inherits both the bearer header and the
  401 handling — don't build a second HTTP client.
- **shadcn `Text` has no `.destructive` style.** The text extensions only cover sizes, weights
  and a few colors (`muted`, `primaryForeground`, …). For error text use
  `Text(x, style: TextStyle(color: ColorScheme.of(context).destructive))`.
- **`Uri.replace` cannot clear a query/fragment.** Passing `query: ''`/`fragment: ''` yields a
  trailing `?#`. `normalizeBaseUrl` (in `server_profile.dart`) builds `uri.origin + path`
  instead, which also strips the trailing slash.
- **The persisted conversation id can dangle.** If the backend's DB was reset, `init()`'s list
  won't contain it; the controller clears the stored id and starts fresh instead of crashing.
- **`RefreshTrigger` needs a scrollable child and a non-zero `minExtent` pull.** It listens for
  scroll notifications at depth 0, so wrap the `ListView`/`SingleChildScrollView` directly (an
  empty state must use `AlwaysScrollableScrollPhysics` or it won't scroll at all). Its `refresh()`
  method is public, which is how the pull-to-refresh tests drive it deterministically — a
  synthetic `tester.drag` does not reliably cross the threshold.
- **`showSettingsDialog` needs the `ChatApi`.** Its signature is
  `(context, settings, auth, api)`; the sidebar passes `chat.api`. Don't build a separate client
  for the MCP status section — that would skip the `401 → logout` path.
- **MCP status JSON never contains secrets.** `McpServerStatus.fromJson` reads only
  name/type/url/connected/toolCount/tools/lastError/lastConnectedAt and ignores anything else,
  so even a hypothetical `headers` field in the payload is never rendered.
- **Don't `await` `StreamController.close()` twice in a widget test.** The second `close()` on
  an already-closed controller never completes under `flutter_test`'s fake async, so the test
  hangs in **teardown** (and `flutter test --timeout` never fires because the test body already
  finished). Guard it — `addTearDown(() => stream.isClosed ? null : stream.close())` — as in
  `chat_usage_test.dart`.
