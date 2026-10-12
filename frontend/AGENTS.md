# AGENTS.md — Procul chat frontend (Flutter)

> **Keep this file up to date.** If you change the structure, conventions, commands, or
> gotchas described here, update this file in the same change. A stale AGENTS.md is worse
> than none. When in doubt, add a short note rather than leaving it wrong. The per-platform build
> guide in [`../docs/flutter-builds.md`](../docs/flutter-builds.md) covers the same commands for a
> human audience — keep it in sync too.

## What this is

The Flutter chat client ("Procul") for the Procul backend. It supports **multiple
conversations** (list, switch, rename, delete), streams assistant replies over SSE, shows
tool activity, renders assistant Markdown, attaches **files** (a paperclip picker with removable
preview chips; images render inline, other files as tap-to-save chips), and has a persisted
**settings** dialog (theme:
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
- **HTTP:** `package:http` (manual SSE parsing; no SSE package) + `http_parser` (the `MediaType`
  for multipart uploads).
- **Files:** [`file_picker`](https://pub.dev/packages/file_picker) (`^13.1.0`) — the composer's
  file picker and tap-to-save, behind the `AttachmentPicker` seam.
  [`image_picker`](https://pub.dev/packages/image_picker) (`^1.2.4`) — the native camera and
  photo-library/gallery sources, behind the same seam.
- **App icon:** `flutter_launcher_icons` (dev) generates every platform's icons from
  `assets/icon/icon.png`; see [`../docs/flutter-builds.md`](../docs/flutter-builds.md).
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
      time_format.dart            # shared relativeTime() (sidebar + Models health rows)
      attachments.dart            # Attachment DTO + size/MIME/`attachmentProblem` helpers +
                                  #   AttachmentSource/AttachmentSources + AttachmentPicker
                                  #   (camera/gallery via image_picker, files via file_picker)
      mcp_status.dart             # McpServerStatus: read-only MCP server status DTO
      mcp_status_controller.dart  # McpStatusController: MCP status for the Settings section
      model_catalog_controller.dart # ModelCatalogController: configured models + default + health
                                  #   checks; owned by the shell (picker + Models screen share it)
      chat_stream_event.dart      # SSE ChatStreamEvent hierarchy (Created/Token/Usage/ToolCall/...)
      chat_api.dart               # ChatApi: authenticated REST + SSE client (Bearer token);
                                  #   conversations, models (+ health checks), usage, MCP status,
                                  #   attachments (multipart upload / authenticated byte fetch)
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
      app_theme.dart              # proculLightTheme / proculDarkTheme (shadcn ThemeData,
                                  #   magenta accent #a832a0 + Inter)
                                  #   + ShadcnMaterialBridge (flutter/material theme for markdown)
      home_shell.dart             # responsive shell: sidebar (wide) / slide-in panel (narrow);
                                  #   owns the ModelCatalogController; overlays UsageScreen/ModelsScreen;
                                  #   lifecycle/periodic sync (WidgetsBindingObserver)
      conversation_sidebar.dart   # conversation list, new chat, usage/models/settings tab row
      conversation_actions.dart   # rename + delete dialogs (shared by sidebar and header)
      settings_dialog.dart        # settings dialog (theme selector + server management)
      chat_screen.dart            # chat pane: header (+ model picker + usage chip, or a single
                                  #   overflow on narrow bars), reversed message list with
                                  #   infinite scroll + bottom pull-to-refresh, per-response
                                  #   popover, composer; streaming shimmer over assistant Markdown
      widgets/
        skeleton.dart             # Shimmer + Skeleton loading placeholders
        icon_action.dart          # IconAction: ghost icon button + tooltip + a11y label + busy spinner
        model_badges.dart         # CapabilityBadge(s) + ModelHealthDot (shared by picker & Models)
        content_width.dart        # kContentMaxWidth + centeredSidePadding (wide-screen measure)
  test/                           # controller, API, auth, settings, and widget tests
  test/support/                   # shared test doubles (FakeConversationStore, FakeCredentialStore,
                                  #   FakeServerStore, FakeAttachmentPicker) + model_fixtures.dart
  test/flutter_test_config.dart   # disables google_fonts runtime fetching for all tests
  linux/ android/ ios/ ...        # platform shells (generated)
  justfile                        # dev/test + per-platform release builds (see ../docs/flutter-builds.md)
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

The `frontend/justfile` wraps these (run from `frontend/`, or `just frontend <recipe>` from the
repo root):

```bash
just get | just analyze | just test | just format | just clean
just run                           # -d linux
just run-web                       # -d chrome
just build-web | just build-linux | just build-windows | just build-macos
just build-android-apk | just build-android-bundle | just build-ios
```

The base URL defaults to `http://localhost:5010`; override without editing code (all `just build-*`
recipes pass it through, and honour the `PROCUL_API_BASE` env var):

```bash
flutter run -d linux --dart-define=PROCUL_API_BASE=http://localhost:5010
```

For **release builds** the API base URL must be the deployed backend's public origin (there is
no default that works in production), and the backend must allow that client's origin via its
`server.corsAllowedOrigins` setting (see [`../docs/flutter-builds.md`](../docs/flutter-builds.md)
for prerequisites, output paths, and signing on every platform):

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
| Start chat | `POST /` body `{"initialMessage":"...","model":"<slug>"?,"attachmentIds":["<guid>"]?}` | SSE |
| Send message | `POST /{id}/messages` body `{"text":"...","attachmentIds":["<guid>"]?,"expectedRevision":<int>?}` | SSE |
| Edit message | `POST /{id}/messages/{messageId}/edit` body `{"text":"...","attachmentIds":["<guid>"]?,"expectedRevision":<int>?}` | SSE (destructive — see below) |
| Upload | `POST /v1/attachments?model=<slug>` multipart (`file` field) | JSON `AttachmentV1` (`201`); `400` (type/model can't read it)/`413` |
| Download | `GET /v1/attachments/{id}` (authenticated) | raw bytes + `Content-Disposition` |
| Delete | `DELETE /v1/attachments/{id}` | `204` (404 treated as success) |
| History | `GET /{id}/messages?limit=1..100&afterMessageId=<guid>` | JSON (user messages carry an `attachments` array of `AttachmentV1`) |
| Rename | `PATCH /{id}` body `{"title":"...","expectedRevision":<int>?}` | JSON `{"conversation":{...}}` (or `409`) |
| Set model | `PUT /{id}/model` body `{"model":"<slug>","expectedRevision":<int>?}` | JSON `{"conversation":{...}}` (or `409`) |
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
data: {"value":{"inputTokens":10,"outputTokens":5,"cachedInputTokens":2,"totalTokens":17,"model":"openai/gpt-4o-mini","type":"usage"}}
data: {"value":{"error":"…","type":"error"}}
data: {"value":{"revision":3,"type":"done"}}
data: {"value":{"conversationId":"…","title":"France's capital","type":"title"}}
```

`created` is only emitted by `POST /`; `POST /{id}/messages` emits
`acknowledge` → (`toolCall` → `toolResult`)* → `token`* → `usage`? → (`error` | `done`).
`usage` (the reply's summed token counts) is emitted just before `done` **only when usage was
seen**; `done` may carry `revision` (the conversation's post-turn revision, echoed back as
`expectedRevision` on the next mutation); `title` is only
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

**Message editing is destructive in v1.** `POST /{id}/messages/{messageId}/edit` rewrites a
**user** message and re-prompts the model. The backend first deletes every message after the
edited one (and their attachments), then returns the same reply stream as send — no `created`,
no `title`. The client mirrors this locally: `ChatController.editMessage` drops the tail, updates
the edited message in place, and inserts a fresh assistant bubble. `attachmentIds` absent keeps
the message's current attachments, `[]` removes all, and a list replaces them; only user messages
are editable. A hard failure triggers a resync (see below).

> **Future branch note** (mirrors the backend): a later version could branch instead of truncate;
> keep the request/response shape compatible.

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
  front and filled in token-by-token as `TokenEvent`s arrive. `attachments` is a mutable final
  list too, so an edit can replace the files while preserving the object's identity (which keeps
  the entrance-animation tracking in `ChatScreen` stable).
- **Editing is destructive and mirrors the backend.** `ChatController.beginEdit(message)` records
  `editingMessageId` and seeds `pendingAttachments` from the message; `cancelEdit()` clears both;
  `editMessage(text)` drops the local tail (`removeRange(index + 1, …)`), rewrites the message in
  place, inserts a fresh assistant bubble, and streams the reply. Only user messages are
  editable, and a persistent `…` `IconAction` on every user bubble opens an **Edit / Copy**
  menu (Edit enters the mode; Copy puts the text on the clipboard) — reachable on touch, not
  hover-only, and disabled mid-turn or while already editing. The composer shows an "Editing
  message" banner with a Cancel action and relabels its send button "Save changes". Edit state
  resets on `newChat()`, `openConversation`, and delete.
- **A hard turn failure resyncs.** When `send`/`editMessage` throws (e.g. the connection drops),
  the controller sets `error` and calls `reloadActiveConversation()` so the buffer matches the
  server rather than leaving a local-only user message.
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
  sidebar's **Usage** tab; `HomeShell` overlays it on top of the
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
  check on the active model. On a narrow app bar the whole trailing collapses to one overflow
  `IconAction` (`compactActions`), whose menu holds Refresh, a **Model** submenu, the usage
  breakdown, Rename and Delete.
- **The Models screen is a read-only catalog with on-demand checks.** `ModelsScreen` renders each
  model's name/description/capability badges/a `Default` pill and a health row (status dot, latency,
  last checked/used, last error), with a per-model **Check** and a **Check all**, plus refresh via
  `RefreshTrigger` + `IconAction`; loading shimmer / empty / error match `UsageScreen`. Health is
  advisory — an unhealthy model stays selectable. It is overlaid on the still-mounted chat like
  Usage, from the sidebar's **Models** tab.
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
- **Branding is one accent and one display name.** Both themes seed `primary`/`ring` from
  `_accent` (`#a832a0`) so the UI, markdown, the web PWA colors and the Android splash agree;
  the **display name is "Procul Chat"** everywhere (Android `android:label`, iOS
  `CFBundleDisplayName`/`CFBundleName`, the Linux `.desktop`, the web manifest, and
  `MaterialShadcnApp(title:)`), while the pubspec package stays `procul_chat_flutter`. Icons are
  generated from `assets/icon/icon.png` by `flutter_launcher_icons` (see
  [`../docs/flutter-builds.md`](../docs/flutter-builds.md)); `test/branding_test.dart` guards this
  static wiring.
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
  `TextInputAction.send` still submits. The Enter/Shift+Enter hint is hidden on touch platforms
  (`defaultTargetPlatform` is Android/iOS), where it would be meaningless.
- **Attachments are picked, uploaded, and queued in `ChatController`.** `ChatScreen` owns an
  `AttachmentPicker` (`FilePickerAttachmentPicker` by default, injected in tests) and a paperclip
  `IconAction` that opens a **Camera / Gallery / Files** source menu (`AttachmentSources`). The
  picker is **restricted to the active model's readable types**:
  `_activeCapabilities()` looks the model up in the shared catalog via `chat.activeModel`, then
  `allowedExtensionsForCapabilities` produces the allow-list (`text/*` always; video never, since
  no model can receive it). A post-pick `attachmentProblem` check (in `attachments.dart`, mirroring
  the backend rule) is the fallback if the platform ignores the filter. `ChatController.uploadAttachments`
  (or `uploadAttachment` for one) then POSTs each — passing the active model so the **backend
  re-validates at upload** — and appends the result to `pendingAttachments` (removable chips;
  disabled while streaming or mid-upload); a multi-select keeps going when one file fails.
  `ChatController.send` snapshots the pending ids into the request and attaches the metadata to the
  user bubble; the queue clears on send, `newChat()`, and switching chats. `pendingAttachments` is
  *not* persisted: a failed turn leaves the uploads orphaned server-side. When a fetch 404s
  (retention purged the bytes) the image falls back to a **"no longer stored"** chip
  (`_ExpiredAttachmentChip`), not a generic file chip.
- **Attachment bytes are fetched through `ChatApi`, then cached.** `ChatController.loadAttachmentBytes`
  does an authenticated `GET /v1/attachments/{id}` and memoizes the **`Future`** (not just the
  bytes) in `_attachmentBytes`, so a rebuild never resets an `Image`'s `FutureBuilder` back to its
  loading placeholder (the same `Future` instance is returned each time; a failed fetch is dropped
  so a retry is possible). Images render as `Image.memory` and other files as chips that fetch the
  bytes and hand them to `picker.save` (`FilePicker.saveFile`) on tap. Never build an `<img>` URL:
  it cannot carry the bearer token. The same path works on web, desktop, and mobile.
- **`AttachmentPicker` is a seam for tests.** `FakeAttachmentPicker` (`test/support/`) records
  `pick`/`save` calls so widget tests never touch the `file_picker` platform channel. Prefer
  `file_picker`'s static API (`FilePicker.pickFiles` / `FilePicker.saveFile`); v13 returns
  `List<PlatformFile>` and saves bytes directly (no `dart:io`).
- **Loading states are hand-rolled shimmer, not spinners.** `widgets/skeleton.dart` provides
  `Shimmer` (one `AnimationController` sweeping a gradient over its children) and `Skeleton`
  blocks. The conversation list and message history show shaped placeholders; an assistant
  bubble awaiting its first token shows pulsing dots (`_ThinkingDots`).
- **Motion is subtle and one-shot** (120–220 ms, `easeOut`): new messages fade + rise once
  (tracked per `ChatMessage` in `ChatScreen`, and suppressed for a whole history load), the
  narrow-screen scrim + panel are driven by one `AnimationController`, and conversation
  tiles/tool rows use `AnimatedContainer` / `AnimatedSwitcher`. Non-essential motion is skipped
  when the platform asks for reduced motion (`MediaQuery.disableAnimationsOf` /
  `accessibleNavigationOf`) — the entrance fade, the streaming shimmer, the thinking dots, the
  send-button scale, and the sidebar slide all respect it.
- **Icon-only buttons go through `IconAction`** (`widgets/icon_action.dart`) so every one has
  a tooltip and an accessible label. `IconAction(busy: true)` swaps the icon for a small spinner
  (used by the refresh buttons).
- **Wide screens cap the content column.** `widgets/content_width.dart` exposes
  `kContentMaxWidth` (900) and `centeredSidePadding(width)`; the chat list and the
  Usage/Models screens add that as horizontal padding, so on an ultra-wide monitor content
  does not pin to the edges. On narrow app bars the whole trailing collapses into one overflow
  menu (`compactActions`).
- **Relative timestamps are shared.** `time_format.dart`'s `relativeTime` backs the
  conversation sidebar, the Models health rows, and the per-response popover.
- **Pull-to-refresh uses `RefreshTrigger` plus an explicit button.** The conversation list
  (`conversation_sidebar.dart`), the chat pane (`chat_screen.dart`) and the MCP section
  (`settings_dialog.dart`) each wrap their scrollable in `RefreshTrigger`; every one also has a
  refresh `IconAction`, because mouse-overscroll on desktop is less discoverable than a drag.
  Empty states are scrollable (`AlwaysScrollableScrollPhysics`) so the gesture still works with
  no content. The chat pane is `RefreshTrigger(reverse: true)` (pull at the **bottom**, matching
  its reversed list) and its `onRefresh` is **null while `chat.isStreaming`** so a pull cannot
  clobber a live stream. `ChatController.refreshAll()` (list + a full active-history reload)
  backs the chat app-bar button; `reloadActiveConversation()` is a no-op when none is active or a
  reply is streaming. `ChatController.loadOlderMessages()` (keyset `afterMessageId`, prepended)
  backs infinite scroll up, and `syncActiveConversation()` (a merge) backs the shell's background
  sync.
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
- **The sidebar's section tabs are tight.** Usage / Models / Settings are
  `SelectedButton`s (compact-density, small) inside `Expanded`s in a 300 px row
  above the chat list, with a `Divider` below them. A widget test asserts
  `takeException()` is null so an overflow fails CI.
- **A `showDropdown` menu needs a `DrawerOverlay` ancestor.** On mobile
  platforms shadcn presents a menu as a bottom sheet, which routes through
  `openRawDrawer` and asserts a `DrawerOverlay` in the tree. The chat pane gets
  one from its `Scaffold`, but the sidebar (and the whole shell on narrow
  screens) does not, so `HomeShell` wraps everything in a root `DrawerOverlay`.
  When a widget calls `showDropdown` from a `State`'s own `context` (which sits
  *above* its `Scaffold`), that lookup misses — so `ChatScreen` threads the
  trigger's own `BuildContext` (via a `Builder`) into `_attach` /
  `_showChatMenu`. Without this the conversation-tile `…` and the app-bar `…`
  silently do nothing on Android/iOS.
- **The chat list is reversed.** `_body` uses `ListView.builder(reverse: true)`
  and indexes `messages[length - 1 - index]`, so offset `0` is the newest message
  (the bottom) and pinning during streaming is a `jumpTo(0)`. Scrolling toward
  the top (older) is near `maxScrollExtent`; the `_trackPin` listener triggers
  `ChatController.loadOlderMessages()` there. The pane is wrapped in
  `RefreshTrigger(reverse: true, …)` so a pull at the **bottom** refreshes
  without scrolling to the top. (`RefreshTrigger.reverse` and `ListView.reverse`
  are two separate coordinate flips; the combination is intentional here.)
- **The app bar collapses to one `…` on narrow screens.** The shadcn `AppBar`
  lays `leading`/`trailing` out at their intrinsic width and gives the title the
  remaining space; with a long title and several actions the trailing overflows
  (painting over the title) and the title's width can collapse to ~0, wrapping
  one character per line — and because the bar uses `IntrinsicHeight`, an N-line
  title makes an N-line-tall bar. `ChatScreen` therefore caps the title with
  `maxLines: 1, overflow: ellipsis` and, when `compactActions` is set (or the
  pane is under 720 px), collapses every action into a single overflow menu
  (`_showChatMenu`: Refresh / Model submenu / Token usage / Rename / Delete).
- **Attachment sources are camera / gallery / files.** The paperclip opens a
  source menu built from `AttachmentSources.available()` (Camera only where
  `ImagePickerPlatform.instance.supportsImageSource(camera)` — hidden on
  desktop/web) intersected with the active model's capabilities (Camera/Gallery
  need the image modality; Files is always offered). The `AttachmentPicker` seam
  has `pickFromCamera` / `pickFromGallery` / `pickFiles`; `image_picker` backs
  camera + gallery, `file_picker` backs files. `ChatController.uploadAttachments`
  uploads a multi-select, keeping going when one file fails. Tests pin camera
  availability via `AttachmentSources.debugCameraSupported` (the platform channel
  is absent under `flutter_test`).
- **A response carries its own model / time / tokens.** `ChatMessage.model` /
  `ChatMessage.usage` are stamped live from the `usage` event (and `createdAt` at
  stream time); tapping an assistant avatar (`Key('response-details')`) opens a
  popover with Model / Time / Input / Output / Cached / Total, degrading to "—"
  when unknown. History carries `model`/`usage` once the backend stores
  per-message metadata (PLAN 2 §B4). The `usage` SSE event may also carry `model`.
- **The shell syncs across devices.** `HomeShell` is a `WidgetsBindingObserver`:
  a `resumed` lifecycle event (and a 25 s periodic timer) calls
  `ChatController.refreshConversations()` plus `ChatController.syncActiveConversation()`,
  skipped while a reply streams or an edit is in progress. `syncActiveConversation` **merges**
  only messages the buffer lacks — it never clears loaded history or moves the viewport, so a
  background tick cannot drop pages loaded by infinite scroll or yank the user to the newest
  message. The explicit chat app-bar/pull-to-refresh uses `refreshAll()` (a full reload) instead.
- **Concurrency is end-to-end.** `Conversation.revision` (parsed from the API and updated by the
  `done` event) is echoed as `expectedRevision` on send / edit / rename / set-model. A `409`
  resyncs — `_resyncAfterConflict` refreshes the **list** (so the revision is current, otherwise
  the next attempt would conflict again) and the active history — then surfaces
  "This chat changed on another device — refreshed." (`ChatApiException.statusCode`).
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
  pinned via the backend's `server.corsAllowedOrigins` setting. In **production there is no
  wildcard** — a Flutter web build served from `https://app.example.com` only works if the
  backend's `server.corsAllowedOrigins` names that exact origin. If Chrome still fails before
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
- **The `INTERNET` permission lives in the main manifest, not just debug/profile.**
  `android/app/src/main/AndroidManifest.xml` declares
  `<uses-permission android:name="android.permission.INTERNET"/>` so **release** builds can
  reach the backend; the debug/profile manifests keep their own copy for the Flutter tool's
  hot reload. Without it in `main`, a release APK/AAB silently has no network access.
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
- **shadcn exports its own `formatFileSize`.** `shadcn_flutter` re-exports a `formatFileSize`
  from its locale utils, so the attachment helper is named **`formatAttachmentSize`** to avoid an
  `ambiguous_import` error. Watch for other one-word names it may already own.
- **A shown toast leaves a pending 5s timer.** `showToast` auto-dismisses after `showDuration`
  (5s), so a widget test that triggers one must `pump(const Duration(seconds: 6))` before
  teardown or `flutter_test` fails with "A Timer is still pending". Assert the toast content
  first, then advance time.
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
