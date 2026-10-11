# Plan: token usage tracking, a usage dashboard, and a streaming shimmer

## Goals

- Capture **token usage** (input / output / cached / total) from every model call the
  backend makes, and **persist** it so it survives restarts.
- Show a **human-readable token counter in the chat app bar** for the active
  conversation (per-conversation cumulative, with an input/output/cached breakdown).
- Add a **Usage** screen reachable from the sidebar next to Settings: a browsable
  **per-day chart**, **lifetime totals**, and (optionally) a per-model breakdown — served
  by the backend and fetched by the client, with **pull-to-refresh**.
- Add a **shimmer sweep** to assistant text while it is being generated.

Work happens on a **new branch** (`feat/token-usage`); commit without pushing, then ask
(per `AGENTS.md`).

### Decisions (confirmed)

| Question | Choice |
| --- | --- |
| Usage screen location | **Sidebar entry beside Settings** (dedicated screen) |
| Metric | **Tokens only** (no dollar cost / pricing config) |
| Chart | **`fl_chart`** (`^1.2.0`) |
| App-bar counter scope | **Per-conversation cumulative** (persisted; survives reload) |
| Streaming animation | **Shimmer sweep** over the text |

### Feasibility notes (already verified)

- `Microsoft.Extensions.AI` 10.10 surfaces **streaming usage** as a `UsageContent` inside
  `ChatResponseUpdate.Contents`; `UsageDetails` exposes `InputTokenCount`,
  `OutputTokenCount`, `CachedInputTokenCount`, `TotalTokenCount`. The OpenAI adapter's
  `FromOpenAIUsage` maps OpenRouter's `prompt_tokens_details.cached_tokens` into
  `CachedInputTokenCount` (confirmed by decompiling `Microsoft.Extensions.AI.OpenAI`).
- The OpenAI .NET SDK requests `stream_options.include_usage` **by default**, so no extra
  request configuration is needed.
- `fl_chart` 1.2.0 (latest) requires Flutter ≥ 3.27.4; the environment is Flutter 3.47.7 /
  Dart 3.13.5 — compatible.

---

## Part A — Backend: capture & persist usage

### A1. New entity `Chat/TurnUsage.cs`

One row per model call (`Kind` distinguishes the main reply from the title call):

```csharp
public class TurnUsage
{
    public Guid Id { get; set; } = Guid.CreateVersion7();
    public Guid ConversationId { get; set; }
    public string Model { get; set; } = "";
    public TurnKind Kind { get; set; }          // Chat | Title
    public long InputTokens { get; set; }
    public long OutputTokens { get; set; }
    public long CachedInputTokens { get; set; }
    public long TotalTokens { get; set; }
    public DateTimeOffset CreatedAt { get; set; } = DateTimeOffset.UtcNow;
}
```

- Register in `ProculDbContext` with a `ConversationId` foreign key (cascade delete) and
  indexes on `ConversationId` and `CreatedAt`.
- Add an EF migration: `dotnet ef migrations add AddTurnUsage`.

### A2. Model slug injection

- Add a tiny `ChatModelOptions` singleton (`Model` = `OPENROUTER_MODEL_SLUG`), registered
  in `AddProculChat`, and inject it into `ChatStreamServiceV1` so each persisted row records
  the model that produced it.

### A3. `ChatStreamServiceV1` capture

- In `StreamTokens`, add `case UsageContent usage:` and **accumulate** the counts (sum across
  the tool-invocation loop, since `UseFunctionInvocation()` can make several underlying calls).
- Emit a single new `usage` SSE event just before `done` when any usage was seen.
- After the reply, persist a `TurnUsage` row with `Kind = Chat`.
- Capture `ChatResponse.Usage` from the **title** call and persist a `Kind = Title` row
  (attributed to the same conversation; no client event needed).

### A4. New SSE payload

In `Chat/V1/ChatStreamEventsV1.cs`:

```csharp
public sealed record ChatStreamUsageV1(
    long? InputTokens,
    long? OutputTokens,
    long? CachedInputTokens,
    long? TotalTokens,
    string Type = "usage");

public sealed record Usage(ChatStreamUsageV1 Value) : ChatStreamEventV1;
```

### A5. New `Usage/` module

```
backend/src/Procul.Api/Usage/
  UsageAggregator.cs          # pure, provider-agnostic bucketing + totals (unit-testable)
  UsageServiceCollectionExtensions.cs   # (only if needed)
  V1/
    UsageEndpointsV1.cs       # GET /v1/usage ; GET /v1/usage/conversations/{id}
    DataTypesV1.cs            # response DTOs (camelCase)
```

- **`UsageAggregator`** (pure functions over `IEnumerable<TurnUsage>` / lightweight rows):
  bucket by **UTC day**, zero-fill missing days in the window, sum input/output/cached/total,
  count turns, and sum totals for the per-model breakdown. Keeping this in C# (rather than a
  provider-specific `GROUP BY`) makes it testable without Postgres and portable.
- **`GET /v{version}/usage?days=30`** (authenticated):

  ```json
  {
    "lifetime": { "inputTokens": 0, "outputTokens": 0, "cachedInputTokens": 0,
                  "totalTokens": 0, "turns": 0 },
    "days": [ { "date": "2026-10-11", "inputTokens": 0, "outputTokens": 0,
                "cachedInputTokens": 0, "totalTokens": 0, "turns": 0 } ],
    "models": [ { "model": "...", "inputTokens": 0, "outputTokens": 0,
                  "cachedInputTokens": 0, "totalTokens": 0, "turns": 0 } ]
  }
  ```

  - `days` is `1–366` (validated → `400 Problem` otherwise). The window drives `days` +
    `models`; `lifetime` is always all-time.
- **`GET /v{version}/usage/conversations/{conversationId}`** → the same totals shape (no
  `days`) for one conversation; drives the in-chat app-bar counter.
- Wire a `Usage` versioned API group in `Program.cs` (mirrors the `Mcp` group).

---

## Part B — Frontend: SSE + in-chat counter

- **`chat_stream_event.dart`**: add `UsageEvent` (input/output/cached/total).
- **`chat_api.dart`**: decode `type: "usage"` in `_decodeEvent`.
- **`models.dart`**: `TokenUsage` model + `formatTokenCount(int)` helper (`999`, `1.0k`,
  `12.4k`, `1.2M`).
- **`chat_controller.dart`**:
  - `activeUsage` (`TokenUsage`) — loaded from
    `GET /v1/usage/conversations/{id}` when a conversation is opened/refreshed, and
    incremented by each `usage` event.
  - `lastTurnUsage` for the most recent reply.
  - Reset on `newChat()`.
- **`chat_screen.dart`**: an app-bar **chip** (e.g. `12.4k tokens`) rendered when the active
  conversation has usage. Tapping opens a small popover (shadcn `showDropdown`) listing
  input / output / cached / total. The chip updates when the turn's usage arrives (in the
  final streamed chunk, i.e. at `done`).

---

## Part C — Frontend: Usage screen (sidebar entry beside Settings)

- **`conversation_sidebar.dart`**: add a **Usage** button (`LucideIcons.chartColumn`) in the
  footer, beside **Settings**, opening the usage screen.
- **`usage.dart`**: DTOs (`UsageSummary`, `UsageDay`, `UsageBreakdown`).
- **`usage_controller.dart`**: `ChangeNotifier` like `McpStatusController` — `summary`,
  `days`, `selectedRange`, `isLoading`, `error`, `load()` / `refresh()` /
  `setRange(...)`.
- **`usage_screen.dart`**:
  - Lifetime cards: **total / input / output / cached tokens** + **turns**.
  - **`fl_chart`** bar chart of the selected range (7 / 30 / 90 / all), with a metric toggle
    (Total / Input / Output) and tappable tooltips → “browsable”.
  - Optional per-model breakdown list.
  - **Pull-to-refresh** via `RefreshTrigger` **plus** an explicit refresh `IconAction`
    (matching the sidebar / chat / MCP conventions).
  - States: loading (shimmer skeleton), empty (`No usage yet`), request failed.
- **`pubspec.yaml`**: add `fl_chart: ^1.2.0`.

---

## Part D — Streaming shimmer

- In `chat_screen.dart`, wrap the assistant's `GptMarkdown` in a `_ShimmerText` stateful
  widget that is active **only while `isStreaming`**: a moving `LinearGradient` highlight
  applied with `ShaderMask` (`BlendMode.srcIn`). It owns its own `AnimationController`, so
  per-token rebuilds do not restart the sweep. Static (no overlay) once the reply completes.

---

## Part E — Tests

### Backend

- `Usage/UsageAggregatorTests`: day bucketing, zero-fill of missing days, totals, empty
  input, window boundaries (records just outside the range), turns count, per-model totals.
- `Chat/SerializationTests` additions: the `usage` SSE event serializes as
  `{"value":{...,"type":"usage"}}`; usage DTOs are camelCase.
- `Chat/UsageStreamingTests`: feed synthetic `ChatResponseUpdate`s (tokens + `UsageContent`,
  plus a tool call) into the streaming seam and assert a single `usage` event with the summed
  counts while tokens still flow. Extend `Support/FakeChatClient` with a **streaming** handler.
- `Integration/UsagePipelineTests` (boots the real app via `WebApplicationFactory`):
  - `GET /v1/usage` → `401` without a token.
  - With a token and an **in-memory EF provider** substituted for Npgsql (connection string
    left unset so migrations are skipped), seeded rows produce the expected `lifetime` /
    `days` / `models` shape.
  - `GET /v1/usage/conversations/{id}` totals.
  - Add `Microsoft.EntityFrameworkCore.InMemory` (10.0.12) to the test project.

### Frontend

- `TokenUsage` formatter + `usage` event decode.
- `UsageController` load / refresh / error / recovery (mirrors `mcp_status_controller_test`).
- Widget tests: the app-bar chip renders and updates from a `usage` SSE event; the Usage
  screen shows summary + chart + empty + error; **pull-to-refresh** refetches.
- Streaming-shimmer presence: shimmer is shown while streaming and gone when done.
- Update existing home-shell / settings / pull-to-refresh tests for the new sidebar entry.
- `flutter analyze` stays clean; `dart format lib test` before committing.

---

## Part F — Docs & workflow

- `backend/AGENTS.md`: new `Usage/` module, the `TurnUsage` entity, the endpoint, and the
  capture seam (accumulating `UsageContent`; summing across the tool loop).
- `frontend/AGENTS.md`: Usage screen + `fl_chart`, the app-bar chip, `TokenUsage`, and the
  streaming shimmer.
- `README.md`: mention token-usage tracking, the Usage screen, and the `GET /v1/usage`
  endpoint in the API table.
- `.env.example` / config: only if a new setting is introduced — **none planned**.
- Run `dotnet test backend/Procul.slnx`, `flutter test`, `flutter analyze`,
  `dart format lib test`; commit; **ask before pushing**.

---

## Behavior summary

1. Every model call (reply and title) records its token usage; the backend persists it.
2. The SSE stream emits a `usage` event before `done`; the client adds it to the open
   conversation's running total.
3. The chat app bar shows a human-readable token chip with an input/output/cached breakdown.
4. A **Usage** entry beside Settings opens a dashboard: lifetime totals, a browsable per-day
   chart (7/30/90/all, Total/Input/Output), optional per-model breakdown, and pull-to-refresh.
5. Assistant text shimmers while it streams and settles once complete.

## Assumptions / notes

- Counts are tokens only — **no dollar estimate** (would need configurable per-model pricing).
- Days are bucketed by **UTC** date.
- Usage is only known for turns whose stream the client observes; the per-conversation total
  is therefore seeded from the backend when a conversation is opened.
- The usage endpoints are authenticated like the rest of `/v1`.
- `fl_chart` is the only new dependency.
