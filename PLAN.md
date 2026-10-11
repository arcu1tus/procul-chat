# PLAN.md — Procul verification, hardening, message editing & docs cleanup

> **Audience:** an AI coding agent (or human) that will implement this against the Procul
> repository. It is self-contained: every task lists the files involved and its acceptance
> criteria. Read `AGENTS.md`, `backend/AGENTS.md`, and `frontend/AGENTS.md` first — they are the
> authoritative conventions and gotchas for each half. This plan assumes they are accurate as of
> the baseline commit; if a listed line/symbol has moved, locate it by name.

---

## 0. Ground rules (standing agreements — do not skip)

- **Start a new branch** at the beginning of implementation: `feat/message-editing`.
- **Commit your work, then ASK before pushing.** Never push without explicit confirmation.
- **Keep the docs fresh in the same change.** If you alter structure, conventions, commands, the
  config shape, or the API surface, update the matching `AGENTS.md` **and** the relevant
  `docs/` page together. A stale doc is worse than none.
- **Timeouts:** start short (~15s). Increase incrementally (15s → 60s → 180s → 600s) only if a
  command genuinely times out. Prefer targeted test runs while iterating; run the full suites
  once at the end. Run long-lived things (dev servers, `docker compose up`) in the background.
- **Keep `flutter analyze` clean** and run `dart format lib test` before committing.
- Treat unfamiliar files/changes as potential user work; investigate before deleting.
- Do not commit secrets. `.env` is git-ignored; document shape in `.env.example`.

## 0.1 Baseline (verified green before starting)

| Command | Result |
| --- | --- |
| `dotnet test backend/Procul.slnx` | 231 passed |
| `flutter analyze` (in `frontend/`) | clean |
| `flutter test` (in `frontend/`) | 101 passed |

If any of these are red when you start, stop and fix the regression first.

## 0.2 Default decisions (apply unless the human says otherwise)

1. **Editing is destructive in v1**: it discards every message after the edited one, rewrites the
   edited message, and re-prompts the model. A future version may branch (keep both versions) —
   document this in the notes (see §5).
2. **Only user messages are editable.**
3. **Attachments on the edited message can be replaced**: `attachmentIds` absent = keep current;
   empty list = remove all; list = replace with exactly those.
4. **Discarded turns' `TurnUsage` rows are deleted too**, so the in-chat counter matches the
   visible branch. (Flip to "keep as a spend record" only if asked.)
5. **Editing does not regenerate the title**, even when the first message is edited.
6. **`.agents/skills/` is left untouched** (harness tooling, not agent notes).

---

## 1. Findings (what to fix and why)

### 1.1 Backend — bugs & edge cases

- **B1 — S3 blobs leak on conversation delete.**
  `backend/src/Procul.Api/Chat/V1/ChatEndpointsV1.cs` → `DeleteConversationAsync` relies on the DB
  cascade (`ConversationMessage → Attachment → AttachmentBlob`). That removes Postgres blob rows,
  but **S3 objects are never deleted**. Fix by collecting each attachment's `StorageKey` and
  calling `IAttachmentStore.DeleteAsync` before removing rows. The same leak will exist in the new
  edit/truncate path (see §2), so fix it once with a shared helper.

- **B2 — No validation of empty message text.**
  `CreateConversationRequestV1.InitialMessage` and `SendMessageRequestV1.Text` are unchecked. A
  blank `initialMessage` creates a conversation titled `"New Conversation"` with an empty user
  turn. Return `400` for empty/whitespace, and add a sane max length (suggest 64 KiB).

- **B3 — `StreamAssistantReplyAsync` always creates its own user message.**
  `backend/src/Procul.Api/Chat/V1/ChatStreamServiceV1.cs`. This blocks reuse for editing (which must
  reply to an *existing* message). Refactor (see §2.1).

- **B4 — History is silently truncated at 100.**
  `frontend/lib/src/chat_api.dart` → `fetchMessages` requests `limit: 100`;
  `GetConversationMessagesAsync` defaults to 20. The UI never pages further, so long chats lose
  their oldest messages. Either implement cursor paging in the UI or document/raise the cap.
  (Low priority — flag if not fixed.)

- **B5 — Missing composite index on messages.**
  History/keyset queries order by `(ConversationId, CreatedAt, Id)`. Add an index via a new EF
  migration.

- **B6 — `GET /v1/usage` loads all rows into memory** (`backend/src/Procul.Api/Usage/V1/UsageEndpointsV1.cs`
  → `ToListAsync`) then aggregates in C#. Fine for a demo; note it, or push aggregation to SQL.

- **B7 — Doc drift in `backend/AGENTS.md`:** it claims the title call is "capped at
  `TitleOptions` = 24 output tokens"; the code is `MaxOutputTokens = 300`. Also
  `MaxTitleWords = 8` while the prompt says "at most 5 words". Fix the docs and reconcile the
  word limit/comment.

- **B8 — Orphaned uploads:** attachments uploaded but never attached (removed pending chip, failed
  send) stay server-side. Document as a known limitation (no GC job). Do not build a GC job in
  this pass.

### 1.2 Frontend — bugs & edge cases

- **F1 — Attachment images flicker on every rebuild.**
  `frontend/lib/src/chat_screen.dart` → `_AttachmentImage` calls `chat.loadAttachmentBytes(...)`
  inside `build` and passes the result to `FutureBuilder`. `loadAttachmentBytes`
  (`frontend/lib/src/chat_controller.dart`) returns a **new** `Future` each call, so every rebuild
  (e.g. each streaming token of a later message) resets the builder to the loading placeholder.
  Bytes are cached; the Future is not. Fix by memoizing the `Future<Uint8List>` (in the controller
  and/or by making `_AttachmentImage` stateful).

- **F2 — App bar can overflow on narrow widths.**
  `chat_screen.dart` chat header has up to 5 trailing items (model picker, usage chip, refresh,
  rename, delete) plus the title. On a small phone that is tight. On narrow layouts collapse
  rename/delete into an overflow menu.

- **F3 — No max content width on ultra-wide screens.**
  The message `ListView` is full-width; only bubbles are capped at 680. On a 2560px monitor user
  bubbles pin to the far right. Add a centered max-width content column for the chat list, and for
  the Usage/Models screens.

- **F4 — `main()` can fail to start offline.**
  `frontend/lib/main.dart` awaits `GoogleFonts.pendingFonts([...])` unguarded; a failed runtime font
  fetch prevents `runApp`. Wrap init/font preloading so the app still starts (fall back to the
  platform face).

- **F5 — Duplicated `_relativeTime`** in `frontend/lib/src/conversation_sidebar.dart` and
  `frontend/lib/src/models_screen.dart`. Extract one shared helper (e.g. `lib/src/widgets/` or a
  small `time_format.dart`).

- **F6 — Composer keyboard hint** (`Enter` / `Shift+Enter`, in `_Composer`) is meaningless on
  touch devices. Hide it on mobile/tablet (use `Theme.of(context).platform` / `defaultTargetPlatform`
  or `MediaQuery`).

- **F7 — `ChatController.send` failure leaves a local-only user message** with no server
  conversation. On a hard failure, resync (`reloadActiveConversation`) so the buffer matches the
  server.

### 1.3 Cross-cutting

- **X1 — Message editing** (backend + frontend) with attachment cleanup. See §2.
- **X2 — Doc drift**: title token count (B7), the new edit endpoint, and edit semantics.
- **X3 — AGENTS.md verbosity** and the need for a "read order" so a new agent doesn't load
  everything. See §6.

---

## 2. Feature: edit a user message (destructive v1)

### 2.1 Backend

**New endpoint** (map it in `ChatEndpointsV1.MapChatV1`, next to the messages routes):

```
POST /v{version}/conversations/{conversationId:guid}/messages/{messageId:guid}/edit
```

- **Auth:** inherits the group's `RequireAuthorization()` (bearer token).
- **Request body** (`EditMessageRequestV1`):
  ```jsonc
  { "text": "the edited message", "attachmentIds": ["<guid>", ...]? }
  ```
  - `text`: required, non-empty after trim, max length (64 KiB).
  - `attachmentIds`: **absent** → keep the message's current attachments; **empty list** → remove
    all; **list** → replace with exactly those.
- **Response:** **SSE**, identical event shape to send:
  `acknowledge → (toolCall/toolResult)* → token* → usage? → (error|done)`.
  No `created`, no `title`.
- **Errors:**
  - `404` conversation not found.
  - `404` message not found / not in this conversation.
  - `400` message is not a `User` message.
  - `400` empty/oversized `text`.
  - `400` unknown attachment id, an id already attached to a *different* message, or a type the
    conversation's model cannot read (reuse `AttachmentGate`).

**`AttachmentGate` change** (`backend/src/Procul.Api/Attachments/AttachmentGate.cs`):
add an optional `Guid? allowMessageId = null` parameter to `ResolveAsync`. When set, an attachment
already attached to **that** message is allowed (it's being kept); one attached to any other
message is still rejected. Keep the existing call sites working via the default.

**`ChatStreamServiceV1` refactor** (`backend/src/Procul.Api/Chat/V1/ChatStreamServiceV1.cs`):

- Extract the reply core into a method that takes an already-persisted user message, e.g.
  ```csharp
  private async IAsyncEnumerable<ChatStreamEventV1> StreamReplyAsync(
      Guid conversationId,
      ConversationMessage userMessage,           // tracked; already persisted
      IReadOnlySet<ModelInputModality> capabilities,
      [EnumeratorCancellation] CancellationToken ct)
  ```
  It: loads the conversation, resolves the model/client, emits `acknowledge`, loads history
  (ordered `CreatedAt, Id`), builds `ChatMessage`s using `message.Id == userMessage.Id` as
  `isCurrentTurn`, streams (existing `StreamTokens`/`CatchToEvent`), persists the assistant reply
  + `TurnKind.Chat` usage, records model use, emits `done`.
- Rewrite the existing `StreamAssistantReplyAsync(conversationId, userText, attachments, ...)` as a
  thin wrapper that creates+persists the user message (attaching files, bumping `UpdatedAt`) and
  then delegates to `StreamReplyAsync`. **Keep its public signature** — existing tests
  (`AttachmentTurnTests`, `ModelSelectionTests`, `UsageStreamingTests`) call it directly.
- Add a public method used by the edit endpoint, e.g.
  ```csharp
  public async IAsyncEnumerable<ChatStreamEventV1> EditMessageAsync(
      Guid conversationId,
      Guid messageId,
      string newText,
      IReadOnlyList<Attachment>? replacementAttachments,   // null = keep current
      IReadOnlySet<ModelInputModality> capabilities,
      [EnumeratorCancellation] CancellationToken ct)
  ```
  Behavior:
  1. Load the tracked `ConversationMessage` (with attachments). (The endpoint has already validated
     existence/role; assert defensively.)
  2. **Truncate:** delete every message with
     `(m.CreatedAt > msg.CreatedAt) || (m.CreatedAt == msg.CreatedAt && m.Id.CompareTo(msg.Id) > 0)`.
     For each such message's attachments, call `IAttachmentStore.DeleteAsync(storageKey)` **before**
     removing rows (fixes the S3 leak). Removing the messages cascades their attachment metadata and
     Postgres blobs.
  3. **Usage:** delete `TurnUsage` rows for the conversation with `CreatedAt > msg.CreatedAt`
     (default decision §0.2.4). Keep the edited turn's own historical usage? No — those rows are
     created at reply time (after the user message), so they are removed and replaced by the new
     reply's row. That is intended.
  4. **Rewrite:** `msg.Text = newText`.
  5. **Attachments (if `replacementAttachments != null`):** remove existing ones whose id is not in
     the replacement (delete bytes + metadata); add the new ones (set `ConversationId`/`MessageId`);
     set the final order to the replacement order. If `null`, leave attachments untouched.
  6. Bump `Conversation.UpdatedAt` (mutate the tracked entity — the in-memory provider used by tests
     does not support `ExecuteUpdateAsync`).
  7. `SaveChangesAsync`.
  8. Delegate to `StreamReplyAsync(conversationId, msg, capabilities, ct)`.

**S3 leak fix in delete** (`ChatEndpointsV1.DeleteConversationAsync`): load the conversation's
attachments' `StorageKey`s (via messages), delete the bytes from `IAttachmentStore`, then remove the
conversation. Prefer a shared helper so edit and delete use the same code.

**Empty-text validation** (B2): validate in `CreateConversationAsync` and `SendMessageAsync` (and
the edit endpoint). Return `TypedResults.Problem(statusCode: 400, detail: ...)`.

**Migration** (B5): add an index on `ConversationMessages (ConversationId, CreatedAt, Id)`. Use:
```bash
PROCUL_CONFIG_PATH=/tmp/config.jsonc PROCUL_API_PASSWORD=x \
  dotnet ef migrations add AddMessageHistoryIndex --project src/Procul.Api
```
(Design-time EF needs a valid config + password — see `backend/AGENTS.md`.)

**New DTOs** (`backend/src/Procul.Api/Chat/V1/DataTypesV1.cs`):
```csharp
public sealed record EditMessageRequestV1(
    string Text,
    [property: JsonIgnore(Condition = JsonIgnoreCondition.WhenWritingNull)] List<Guid>? AttachmentIds = null);
```

### 2.2 Frontend

**`ChatApi`** (`frontend/lib/src/chat_api.dart`): add
```dart
Stream<ChatStreamEvent> editMessage(
  String conversationId,
  String messageId,
  String text, {
  List<String>? attachmentIds,   // null = keep; [] = remove all; list = replace
}) => _stream(_postSse(
  '/v1/conversations/$conversationId/messages/$messageId/edit',
  {
    'text': text,
    if (attachmentIds != null) 'attachmentIds': attachmentIds,
  },
));
```

**`ChatController`** (`frontend/lib/src/chat_controller.dart`):
- Add `String? editingMessageId` and `bool get isEditing => editingMessageId != null`.
- `void beginEdit(ChatMessage message)`: set `editingMessageId = message.id`; copy
  `message.attachments` into `pendingAttachments`; `notifyListeners()`. (UI reads the message text
  from the message and fills the input.)
- `void cancelEdit()`: clear `editingMessageId` and `pendingAttachments`; `notifyListeners()`.
- `Future<void> editMessage(String text)`: guard `isStreaming`, `hasConversation`,
  `editingMessageId != null`. Snapshot `pendingAttachments` (these are the desired attachments).
  Find the edited message's index in `messages`; `removeRange(index + 1, messages.length)`; set the
  edited message's `text` and attachments; insert a fresh empty assistant placeholder; set
  `isStreaming = true`; clear the pending queue and `editingMessageId`; notify. Stream
  `api.editMessage(...)` handling the same event cases as `send` (token/tool/usage/done/error). On
  completion set `isStreaming = false`; on a thrown error set `error` and call
  `reloadActiveConversation()` to resync with the server.
- Reset edit state in `newChat()`, `selectConversation`/`_openConversation`, and
  `deleteConversation`.

**`ChatMessage.attachments`** (`frontend/lib/src/models.dart`): make it a **mutable** list (keep it
`final` but stop wrapping in `List.unmodifiable`, i.e. `attachments = List.of(attachments)`), so an
edit can replace the attachments while preserving object identity (which keeps the
`_seenMessages` entrance-animation tracking in `chat_screen.dart` stable). `toolCalls` is already a
mutable final list, so this is consistent.

**UI** (`frontend/lib/src/chat_screen.dart`):
- Show a hover "Edit" `IconAction` on **user** bubbles only (mirror the conversation tile's
  hover-reveal ellipsis pattern in `conversation_sidebar.dart`). Hidden/disabled while
  `chat.isStreaming`.
- Tapping it calls `_beginEdit(message)`: `chat.beginEdit(message)`, set the input controller text to
  `message.text`, move the caret to the end, focus the field, pin to bottom.
- In `_Composer`, when `chat.isEditing`, render an "Editing message" banner above the field with a
  Cancel (`X`) `IconAction` that calls `chat.cancelEdit()` and clears the input; change the send
  button label/tooltip to "Save changes".
- `_submit()` branches: when editing, call `chat.editMessage(text)` instead of `chat.send(text)`.

### 2.3 Tests for the edit feature

**Backend (new file `backend/tests/Procul.Api.Tests/Chat/EditMessageTests.cs`)** — service-level with
the in-memory provider and fake clients, following `AttachmentTurnTests`/`ModelSelectionTests`:
- Editing a middle message deletes every later message and persists exactly one new assistant reply.
- The edited message's text is updated; earlier messages are untouched.
- Attachments on discarded messages are removed from the store **and** the DB (use
  `FakeAttachmentStore`).
- `replacementAttachments = null` keeps the message's attachments.
- An empty replacement removes all attachments (bytes + metadata).
- A replacement set adds the new attachments to the edited message.
- Discarded turns' `TurnUsage` rows are deleted; the new reply adds one.
- `UpdatedAt` is bumped.

**Backend integration (extend `Integration/AttachmentPipelineTests.cs` or a new
`Integration/EditPipelineTests.cs`)** — boot the real app with `ReplaceDbWithInMemory` +
`ReplaceModels(fakeClient)` as `AttachmentPipelineTests` does:
- Auth required.
- `404` unknown conversation / unknown message; `400` editing an assistant message; `400` empty
  text.
- End-to-end: create a conversation (2 turns), `POST .../edit`, drain the SSE, assert via a direct
  `ProculDbContext` scope that the tail is gone, the text changed, and the reply was persisted.
- `400` when `attachmentIds` references an id already attached to a different message.

**Frontend (new file `frontend/test/chat_edit_test.dart`)**:
- `MockClient` returning an edit SSE stream; assert the tail is truncated, the edited text updated,
  the new reply streamed, and `isEditing` cleared.
- Error path resyncs (assert a follow-up `GET .../messages` is issued).
- Widget test: tapping the user bubble's Edit action enters edit mode (banner + prefilled text), and
  submitting calls the edit endpoint. Use `setSurfaceSize` and the existing `FakeAttachmentPicker` /
  `FakeConversationStore` doubles.

---

## 3. Backend correctness fixes (non-edit)

- **B2** empty/oversized text validation on create/send (+ tests in the pipeline tests or a focused
  unit test).
- **B1** delete S3 bytes on conversation delete.
- **B5** message-history index migration.
- **B7** fix `backend/AGENTS.md` title-token claim (300, not 24) and the word-count comment; keep
  code and docs consistent.
- **(Optional / flag)** B4 history pagination and B6 SQL-side usage aggregation.

## 4. Frontend correctness, robustness & responsive scaling

- **F1** memoize attachment byte futures (fix the flicker). Add a widget test that rebuilds the list
  (e.g. pump a streaming token for a later message) and asserts the image does not return to the
  placeholder state.
- **F4** guard `main()` font/init preloading.
- **F5** extract a shared `_relativeTime` helper and use it in both places.
- **F7** resync on hard send failure.
- **F3** centered max-width content column for the chat list and Usage/Models screens.
- **F2** overflow menu for rename/delete on narrow app bars.
- **F6** hide the keyboard hint on touch platforms.
- **Responsive tests (new file `frontend/test/responsive_layout_test.dart`)** at several surface
  sizes — e.g. `360×640`, `768×1024`, `1400×900`, `2560×1440` — asserting
  `tester.takeException() == null` and that the composer, send button, and sidebar/menu button are
  reachable. This turns overflow/scale regressions into CI failures.

## 5. Light UI polish (do not overdo)

Keep the existing design language (shadcn, Inter/Coiny, shimmer, subtle 120–220 ms motion). Only:
- the new Edit affordance and its banner,
- consistent icon sizing,
- the wide-screen measure,
- small empty-state spacing tweaks.

No redesign, no new dependencies.

## 6. Docs: AGENTS.md cleanup + feature docs

Goal: **readable and token-efficient, without losing any gotcha or contract detail.**

- **Root `AGENTS.md`:** keep it as the map + standing rules + timeout policy. Remove the feature
  restatement that duplicates `README.md`. Add a short "read order" block, e.g.:
  *touching backend code → `backend/AGENTS.md`; frontend → `frontend/AGENTS.md`; config →
  `docs/configuration.md`; deploy → `docs/docker-compose.md`; builds → `docs/flutter-builds.md`.*
- **`backend/AGENTS.md` / `frontend/AGENTS.md`:** reorganize both into one consistent skeleton:
  *Quick map → Build/run/test → Contracts → Conventions → Subsystems → Gotchas*. Compress the
  file-by-file Layout block (it duplicates the directory tree) into a short "key files" list.
  **Link** to `docs/configuration.md` instead of repeating field tables. **Keep every gotcha** but
  tighten the wording. Aim for roughly a 30–40% size reduction each.
- **Document the new feature:** add the edit endpoint to the API-surface table, describe the
  destructive semantics, and add the future-branching note (below). Add a feature bullet to
  `README.md` and `frontend/README.md`.
- **`.agents/skills/`:** leave untouched.

### Future-agent note (add to both `backend/AGENTS.md` and `frontend/AGENTS.md`, and the README)

> **Message editing is destructive in v1.** Editing a user message deletes every message after it
> (and their attachments/bytes) and re-prompts the model. A future version could instead **branch**
> the conversation, keeping both versions (e.g. a message tree / parent-leaf model, or
> soft-deleting the discarded tail and offering a "switch branch" control). Keep the edit endpoint's
> request/response shape compatible with that evolution.

## 7. Verification (run at the end)

```bash
# from repo root
just check                 # backend tests + frontend tests + frontend analyze

# or individually
dotnet test backend/Procul.slnx
cd frontend && flutter analyze && flutter test && dart format lib test
```

- All previously green tests still pass (231 backend / 101 frontend + new ones).
- `flutter analyze` is clean; `dart format` reports no changes.
- The new responsive widget tests pass at every surface size.
- Manually (if a dev DB is available): create a chat with 2+ turns, edit an earlier user message,
  confirm the tail disappears, the edited text is sent, the new reply streams, and attachments on
  the discarded messages are gone (check `GET /v1/attachments/{id}` → 404 for removed ones).

---

## 8. File-by-file task index

**Backend**
- `src/Procul.Api/Chat/V1/ChatStreamServiceV1.cs` — refactor reply core; add `EditMessageAsync`.
- `src/Procul.Api/Chat/V1/ChatEndpointsV1.cs` — map the edit route; empty-text validation; S3-aware
  conversation delete.
- `src/Procul.Api/Chat/V1/DataTypesV1.cs` — `EditMessageRequestV1`.
- `src/Procul.Api/Attachments/AttachmentGate.cs` — `allowMessageId` parameter.
- `src/Procul.Api/Attachments/IAttachmentStore.cs` / stores — ensure delete-by-key is used by the
  new truncation path.
- `src/Procul.Api/Infrastructure/DbContext.cs` + `Migrations/` — message-history index.
- Tests: `tests/.../Chat/EditMessageTests.cs`, `tests/.../Integration/EditPipelineTests.cs`
  (or extend `AttachmentPipelineTests.cs`).

**Frontend**
- `lib/src/chat_api.dart` — `editMessage`.
- `lib/src/chat_controller.dart` — edit state + `beginEdit`/`cancelEdit`/`editMessage`; resync on
  failure; reset on chat switches.
- `lib/src/models.dart` — mutable `ChatMessage.attachments`.
- `lib/src/chat_screen.dart` — edit affordance, edit banner, submit branch, attachment-future
  memoization, wide-screen measure, narrow overflow menu, touch keyboard-hint hiding.
- `lib/src/conversation_sidebar.dart` / `lib/src/models_screen.dart` — shared relative-time helper.
- `lib/main.dart` — guarded font/init preloading.
- Tests: `test/chat_edit_test.dart`, `test/responsive_layout_test.dart`, plus the attachment-flicker
  test.

**Docs**
- `AGENTS.md`, `backend/AGENTS.md`, `frontend/AGENTS.md`, `README.md`, `frontend/README.md`,
  and the API tables (and `docs/configuration.md` only if config shape changes — it should not).

## 9. Open questions (defaults in §0.2 apply if unanswered)

1. Delete discarded turns' `TurnUsage` (default) or keep it as a spend record?
2. Regenerate the title when the **first** message is edited (default: no)?
3. Should B4 (history paging beyond 100) and B6 (SQL usage aggregation) be in scope now, or noted
   for later?
