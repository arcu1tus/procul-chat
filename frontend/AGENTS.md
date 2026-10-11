# AGENTS.md — Procul chat frontend (Flutter)

> **Keep this file up to date.** If you change the structure, conventions, commands, or
> gotchas described here, update this file in the same change. A stale AGENTS.md is worse
> than none. When in doubt, add a short note rather than leaving it wrong.

## What this is

The Flutter chat client ("Procul") for the Procul backend. It supports **multiple
conversations** (list, switch, rename, delete), streams assistant replies over SSE, shows
tool activity, renders assistant Markdown, and has a persisted **settings** dialog (dark
mode, default on). It talks to the backend's versioned `/v1/conversations` API.

- **Flutter** (Dart `^3.13.5`).
- **UI:** [`shadcn_flutter`](https://pub.dev/packages/shadcn_flutter) (`^0.0.55`) — the app
  is built on shadcn components and the **New York** theme, not Material.
  `shadcn_flutter_material` provides a Material interop layer (see gotchas).
- **Markdown:** `gpt_markdown` (`^1.3.4`) renders assistant replies (code, lists, bold).
- **HTTP:** `package:http` (manual SSE parsing; no SSE package).
- **Persistence:** `package:shared_preferences` — the active conversation id and settings.
- **State:** plain `ChangeNotifier`s surfaced with `ListenableBuilder`. No
  provider/riverpod/bloc.

The backend lives in `../backend` and its contract is documented in `../backend/AGENTS.md`.

## Layout

```
frontend/
  lib/
    main.dart                     # entrypoint, MaterialShadcnApp, base-URL const
    src/
      models.dart                 # domain types: Conversation, ChatMessage, ToolCall, MessageRole
      chat_stream_event.dart      # SSE ChatStreamEvent hierarchy (Created/Token/ToolCall/...)
      chat_api.dart               # ChatApi: REST (list/rename/delete) + SSE client
      conversation_store.dart     # ConversationStore: active conversation id (shared_preferences)
      settings_store.dart         # SettingsStore: persisted preferences (shared_preferences)
      settings_controller.dart    # SettingsController: theme mode (dark default)
      chat_controller.dart        # ChatController: conversation list + active buffer + turn logic
      app_theme.dart              # proculLightTheme / proculDarkTheme (shadcn ThemeData)
                                  #   + ShadcnMaterialBridge (flutter/material theme for markdown)
      home_shell.dart             # responsive shell: sidebar (wide) / slide-in panel (narrow)
      conversation_sidebar.dart   # conversation list, new chat, settings footer
      conversation_actions.dart   # rename + delete dialogs (shared by sidebar and header)
      settings_dialog.dart        # settings dialog (dark mode switch)
      chat_screen.dart            # chat pane: header, message list, composer
  test/                           # controller, API, settings, and widget tests
  test/support/                   # shared test doubles (e.g. FakeConversationStore)
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

## Backend contract (v1) as consumed here

Base: `{PROCUL_API_BASE}/v1/conversations`.

| Action | Request | Response |
| --- | --- | --- |
| List chats | `GET /` | JSON `{"conversations":[...]}`, newest activity first |
| Start chat | `POST /` body `{"initialMessage":"..."}` | SSE |
| Send message | `POST /{id}/messages` body `{"text":"..."}` | SSE |
| History | `GET /{id}/messages?limit=1..100&afterMessageId=<guid>` | JSON |
| Rename | `PATCH /{id}` body `{"title":"..."}` | JSON `{"conversation":{...}}` |
| Delete | `DELETE /{id}` | `204` (404 treated as success) |

**SSE wire format.** There is **no `event:` field**; each event is a `data: <json>` line
followed by a blank line, and the kind is a `type` discriminator *inside* the JSON under
`value`:

```
data: {"value":{"conversation":{"id":"…","title":"…","createdAt":"…","updatedAt":"…"},"type":"created"}}
data: {"value":{"message":"received","type":"acknowledge"}}
data: {"value":{"callId":"…","name":"get_current_time","arguments":"{\"utcOffsetMinutes\":120}","type":"toolCall"}}
data: {"value":{"callId":"…","result":"2026-10-11T15:38:44+02:00","error":null,"type":"toolResult"}}
data: {"value":{"content":"Hello","type":"token"}}
data: {"value":{"error":"…","type":"error"}}
data: {"value":{"type":"done"}}
data: {"value":{"conversationId":"…","title":"France's capital","type":"title"}}
```

`created` is only emitted by `POST /`; `POST /{id}/messages` emits
`acknowledge` → (`toolCall` → `toolResult`)* → `token`* → (`error` | `done`). `title` is only
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
- **Errors are user-facing strings** on `ChatController.error`; `ChatScreen` shows them as a
  shadcn toast. Streaming failures still leave the partial reply in the bubble.
- **Settings are a `ChangeNotifier` + `shared_preferences`.** `SettingsController.themeMode`
  defaults to `ThemeMode.dark`. `main.dart` rebuilds `MaterialShadcnApp` from it.
- **All UI is shadcn_flutter.** Use shadcn components (`Scaffold` + `headers: [AppBar(...)]`,
  `PrimaryButton`/`OutlineButton`/`DestructiveButton`/`GhostButton`, `TextField`, `Switch`,
  `AlertDialog` via `showOverlay`, `DropdownMenu` via `showDropdown`, `showToast`,
  `Clickable`) and `LucideIcons`. There is no Material `ScaffoldMessenger`/`SnackBar` usage.
- **Text styles are extension getters**, e.g. `Text('x').muted.small`, `.semiBold.large`.

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
- **Use `http.Client.send()` with a `http.Request`, not `client.post()`.** `post()` buffers
  the whole body into a `Response`; SSE needs the `StreamedResponse` from `send()`.
- **`Client.send()` only streams on real IO clients.** Fine on desktop/mobile; on web the
  browser `fetch`/XHR layer also buffers by default, so streaming may not be incremental
  there.
- **CORS.** Native Linux/desktop (the intended target) has no CORS. Running `-d chrome`
  sends requests from the Flutter web dev-server origin to the backend's origin, so the
  browser enforces CORS; the backend must approve the origin. It now does: in development the
  `ProculCors` policy allows any origin (the web dev-server port is ephemeral), and it can be
  pinned via the backend's `CORS_ALLOWED_ORIGINS` setting. If Chrome still fails before
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
- **The persisted conversation id can dangle.** If the backend's DB was reset, `init()`'s list
  won't contain it; the controller clears the stored id and starts fresh instead of crashing.
