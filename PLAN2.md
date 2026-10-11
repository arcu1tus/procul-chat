# PLAN2 — Multi-model frontend + Models catalog

> **Series:** this is **Plan 2 of 4**. **Depends on Plan 1** (the backend must expose
> `GET /v1/models`, per-conversation `model`, and `PUT /v1/conversations/{id}/model`).
> Start a **new branch** (`feat/multi-model-ui`); commit without pushing; ask before pushing.

## Why this plan exists

Plan 1 makes the backend multi-model but the client still sends no model and shows no picker. This
plan surfaces the models: a **per-conversation model dropdown in the chat app bar**, a **Models
entry in the sidebar footer** beside Usage + Settings, and a **Models screen** listing every
configured model with its name, description, capability badges, and live health status.

## Prerequisites (from Plan 1)

- `GET /v1/models` → `{ defaultModel, models[] }` with
  `slug, name, description, provider, isDefault, capabilities { input[], output[] }, health`.
- `POST /v1/models/check` and `POST /v1/models/{slug}/check`.
- `Conversation` JSON includes `model`; `POST /v1/conversations` accepts `model`;
  `PUT /v1/conversations/{id}/model` sets it.

## Non-goals

- Attachments (Plan 3).
- Docs site / justfiles / AGENTS overhaul (Plan 4).

---

## Part A — API client + models

- **`lib/src/models.dart`**: add
  - `enum ModelInputModality { text, image, file, audio, video }` (+ `fromValue` fallback),
  - `class ModelCapabilities { Set<ModelInputModality> input; Set<String> output; }`,
  - `enum ModelHealthStatus { unknown, healthy, unhealthy }` (+ `fromValue` fallback),
  - `class ModelHealth { status, lastCheckedAt, latencyMs, lastError, lastUsedAt, source }`,
  - `class ChatModel { slug, name, description, provider, isDefault, capabilities, health }`.
- **`lib/src/chat_api.dart`**:
  - `Future<List<ChatModel>> fetchModels()` → `GET /v1/models`.
  - `Future<void> checkModels()` and `Future<void> checkModel(String slug)`.
  - `Future<Conversation> setConversationModel(String id, String slug)` → `PUT .../model`.
  - `createConversation(String initialMessage, {String? model})` adds `model` to the body.
  - All go through `ChatApi` so they inherit the bearer header and the `401 → logout` path.
- **`lib/src/chat_stream_event.dart`**: no change (models aren't streamed).

## Part B — Controllers

- **`lib/src/model_catalog_controller.dart`** (mirrors `McpStatusController`): owns
  `List<ChatModel> models`, `String? defaultModel`, `isLoading`, `error`; `load()`/`refresh()`;
  `check(slug)` / `checkAll()` which call the API then refresh. Owned by the shell so both the
  app-bar dropdown and the Models screen share one source.
- **`lib/src/chat_controller.dart`**:
  - `String? get activeModel` — the active conversation's model, else `defaultModel`.
  - `setModel(String slug)` — optimistically updates the active conversation, calls
    `ChatApi.setConversationModel`, rolls back on failure (same pattern as `renameConversation`).
  - `send` passes the model only when creating a conversation (`newChat` uses `defaultModel` or
    the last explicitly chosen model for a brand-new chat — see Part C).
  - Keep `activeUsage`/`lastTurnUsage` behavior unchanged.

## Part C — App-bar model dropdown (per conversation)

- In `lib/src/chat_screen.dart`, add a `_ModelPicker` in the `AppBar.trailing` (before the usage
  chip): a compact button showing the active model's `name` (or `slug`), opening a shadcn
  `showDropdown`/`DropdownMenu` listing every model with a check on the active one.
  - Selecting calls `chat.setModel(slug)`; disabled while `chat.isStreaming`.
  - Hidden/disabled when only one model is configured (nothing to pick).
  - New chat (no conversation yet): choosing a model sets a pending selection used on the first
    `send` (so `createConversation` includes it).
- Show capability/health hints in the menu rows (e.g. a small dot for `unhealthy`, badges for
  `image`/`audio`), so a broken model is visible before sending.

## Part D — Sidebar entry + Models screen

- **`lib/src/conversation_sidebar.dart`**: add a third footer entry **Models**
  (`LucideIcons.blocks` or `boxes`) beside Usage + Settings, calling `onOpenModels`.
  - The footer is a 300 px-wide `Row` of `Expanded` buttons; three equal buttons are tight. Make
    the row responsive: keep the icon + short label, reduce horizontal padding, and let labels
    ellipsize. (Do **not** cram; if needed, switch to a 2-line layout.)
- **`lib/src/home_shell.dart`**: mirror the Usage overlay with `_showModels` /
  `onOpenModels`, overlaying `ModelsScreen` over the still-mounted chat (preserve scroll/buffer).
- **`lib/src/models_screen.dart`** (new):
  - Header with a refresh `IconAction` **and** a "Check all" action (`model_catalog_controller`).
  - Per model: `name` (medium), `description` (muted), capability badges (Text/Image/File/Audio/
    Video), a `Default` pill, and a health row (status dot, latency, `lastCheckedAt`,
    `lastUsedAt`, `lastError`), with a per-model "Check" `IconAction`.
  - States: loading shimmer (reuse `widgets/skeleton.dart`), empty ("No models configured"),
    error. `RefreshTrigger` + explicit button, matching the app conventions.
  - A short caption explaining that unhealthy models are re-checked periodically and that a model
    with recent traffic is considered live.

## Part E — UI/UX polish (light touch)

- Consistent disabled state for the composer/model picker while streaming.
- The model picker and usage chip should not crowd the app bar on narrow screens: collapse the
  picker to an icon on narrow widths (reuse the `showMenuButton`/breakpoint pattern).
- Ensure new controls have tooltips + a11y labels via `IconAction`/`Semantics`.
- No redesign; only what the new controls require.

## Part F — Tests

- `test/model_catalog_controller_test.dart`: load / refresh / error / recovery; `check` refreshes.
- `test/models_screen_test.dart`: renders names + descriptions + capability badges; healthy vs
  unhealthy; empty; error; "Check all" and per-model check call the API (fake `http.Client`).
- `test/chat_model_selection_test.dart`: the app-bar picker shows the active model; selecting calls
  `setConversationModel`; the pending selection is sent on `createConversation`; picker disabled
  while streaming.
- Update `test/home_shell_test.dart`, `test/settings_*`, `test/pull_to_refresh_test.dart` for the
  new sidebar entry (three footer buttons) and the Models overlay.
- Extend `test/support/` with a fake `ChatApi`/HTTP helper for `/v1/models` if not already present.
- `flutter analyze` must stay clean; `dart format lib test` before committing.

## Part G — Docs & workflow

- `frontend/AGENTS.md`: the Models controller/screen, the app-bar model picker, per-conversation
  model selection, the sidebar footer layout, and the new `ChatApi` methods.
- `README.md`: mention the per-conversation model picker + Models screen.
- Run `flutter test`, `flutter analyze`, `dart format lib test`; commit; **ask before pushing**.

## Behavior summary

1. The app bar shows the conversation's model; changing it persists server-side.
2. A brand-new chat uses the default model unless the user picks one first.
3. The sidebar's **Models** entry opens a catalog with names, descriptions, capability badges, and
   live health, with on-demand checks.
4. Only one model configured → the picker is hidden (no noise).

## Assumptions / notes

- `ModelHealth` is advisory: an unhealthy model is still selectable (the user may know better);
  the backend is the source of truth for the actual call.
- Capability badges reflect discovered ∪ declared capabilities from the backend.
