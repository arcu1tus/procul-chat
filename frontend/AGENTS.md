# AGENTS.md — Procul chat frontend (Flutter)

> **Keep this file up to date.** If you change the structure, conventions, commands, or
> gotchas described here, update this file in the same change. A stale AGENTS.md is worse
> than none. When in doubt, add a short note rather than leaving it wrong.

## What this is

A deliberately minimal Flutter chat client ("Procul") for the Procul backend. It is a
proof-of-concept: one screen, one conversation, in-memory message buffer, no routing, no
state-management package. It talks to the backend's versioned `/v1/conversations` API,
creating a conversation on the first message and streaming assistant replies over SSE.

- **Flutter** (Material 3), Dart `^3.13.5`.
- **HTTP:** `package:http` (manual SSE parsing; no SSE package).
- **Persistence:** `package:shared_preferences` — only to remember the active
  conversation id across launches.
- **State:** a single `ChangeNotifier` (`ChatController`) surfaced with
  `ListenableBuilder`. No provider/riverpod/bloc.

The backend lives in `../backend` and its contract is documented in `../backend/AGENTS.md`.

## Layout

```
frontend/
  lib/
    main.dart                     # entrypoint, MaterialApp, base-URL const
    src/
      models.dart                 # Conversation, ChatMessage (+ToolCall), ChatStreamEvent hierarchy
      chat_api.dart               # ChatApi: REST + SSE client over package:http
      conversation_store.dart     # ConversationStore: shared_preferences wrapper
      chat_controller.dart        # ChatController: ChangeNotifier, buffer + turn logic
      chat_screen.dart            # ChatScreen: message list, composer, "new chat"
  test/
    chat_tool_events_test.dart    # controller tool-call handling (MockClient SSE)
  linux/ android/ ios/ ...        # platform shells (generated)
  pubspec.yaml
```

## Build / run / test

The backend must already be running (dev: `http://localhost:5010`).

```bash
cd frontend
flutter pub get
flutter analyze
flutter test                       # unit tests (no backend needed)
flutter run -d linux              # native Linux desktop
flutter run -d chrome             # web (needs CORS on the backend — see gotchas)
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
| Start chat | `POST /` body `{"initialMessage":"..."}` | SSE |
| Send message | `POST /{id}/messages` body `{"text":"..."}` | SSE |
| History | `GET /{id}/messages?limit=1..100&afterMessageId=<guid>` | JSON |

**SSE wire format.** There is **no `event:` field**; each event is a `data: <json>` line
followed by a blank line, and the kind is a `type` discriminator *inside* the JSON under
`value`:

```
data: {"value":{"conversation":{"id":"…","title":"…","createdAt":"…"},"type":"created"}}
data: {"value":{"message":"received","type":"acknowledge"}}
data: {"value":{"callId":"…","name":"get_current_time","arguments":"{\"utcOffsetMinutes\":120}","type":"toolCall"}}
data: {"value":{"callId":"…","result":"2026-10-11T15:38:44+02:00","error":null,"type":"toolResult"}}
data: {"value":{"content":"Hello","type":"token"}}
data: {"value":{"error":"…","type":"error"}}
data: {"value":{"type":"done"}}
```

`created` is only emitted by `POST /`; `POST /{id}/messages` emits
`acknowledge` → (`toolCall` → `toolResult`)* → `token`* → (`error` | `done`). Tool events
only appear when the model actually calls a tool, and correlate via `callId` (`arguments` is a
JSON object string; `result` is the tool output and `error` its failure message). Parse
accordingly in `ChatApi._decodeEvent`.

**JSON is camelCase** (`initialMessage`, `messageRole`, `createdAt`).

**`messageRole` is an integer**, not a string: `0=System, 1=User, 2=Assistant, 3=Tool`
(the C# enum ordinal). Map it in `models.dart` via `messageRoleFromValue`; unknown values
fall back to `user`.

**History is newest-first** (`ORDER BY CreatedAt DESC, Id DESC`) and keyset-paginated with
`afterMessageId`. `ChatApi.fetchMessages` reverses the page to oldest-first before it
reaches the buffer.

## Conventions & patterns

- **In-memory buffer, fetch once.** `ChatController.init()` loads the persisted
  conversation id and does a single `GET .../messages` into `messages`. Assistant replies
  are then **appended from the SSE stream** — do **not** re-fetch history after a turn.
  If you add pagination, load older pages into the front of the buffer rather than
  replacing it.
- **`ChatMessage.text` is mutable** on purpose: an empty assistant bubble is inserted up
  front and filled in token-by-token as `TokenEvent`s arrive.
- **Tool activity lives on the assistant message.** `ToolCallEvent`/`ToolResultEvent` are
  folded into the streaming assistant `ChatMessage.toolCalls` (matched by `callId`), not added
  as separate buffer entries, so the call/result rows render above the reply text in order.
  Tool calls are not persisted, so they vanish when history is reloaded — that's expected.
- **Errors are user-facing strings** on `ChatController.error`; the screen shows them via a
  `SnackBar`. Streaming failures still leave the partial reply in the bubble.
- **One conversation at a time.** `newChat()` clears the buffer and the stored id so the
  next send hits `POST /` again. There is intentionally no conversation list.
- **Dependencies stay minimal.** Reach for a package only when it removes real complexity;
  this is a PoC, not the product.

## Gotchas (learned the hard way)

- **Use `http.Client.send()` with a `http.Request`, not `client.post()`.** `post()` buffers
  the whole body into a `Response`; SSE needs the `StreamedResponse` from `send()`.
- **`Client.send()` only streams on real IO clients.** Fine on desktop/mobile; on web the
  browser `fetch`/XHR layer also buffers by default, so streaming may not be incremental
  there.
- **CORS.** Native Linux/desktop (the intended target) has no CORS. Running `-d chrome`
  requires the backend to allow the web origin; otherwise requests fail before streaming.
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
- **`flutter analyze` must stay clean.** `dart format lib` before committing.
- **The persisted conversation id can dangle.** If the backend's DB was reset, `init()`'s
  `GET` 404s; the controller catches it, clears the stored id, and starts fresh instead of
  crashing.
