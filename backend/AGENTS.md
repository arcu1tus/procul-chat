# AGENTS.md — Procul chat backend

> **Keep this file up to date.** If you change the structure, conventions, commands, or
> gotchas described here, update this file in the same change. A stale AGENTS.md is worse
> than none. When in doubt, add a short note rather than leaving it wrong.

## What this is

Backend for a chat app ("Procul"). It exposes a versioned minimal-API HTTP surface that
creates conversations, streams assistant replies over Server-Sent Events (SSE), and reads
message history. Persistence is PostgreSQL via EF Core; the LLM is called through
`Microsoft.Extensions.AI` against OpenRouter.

- **Framework:** .NET 10 (`net10.0`), ASP.NET Core minimal APIs, `CreateSlimBuilder`.
- **DB:** PostgreSQL + `Npgsql.EntityFrameworkCore.PostgreSQL`, `AddDbContextPool`.
- **AI:** `Microsoft.Extensions.AI` + `Microsoft.Extensions.AI.OpenAI`, OpenRouter endpoint.
- **Tools:** `AIFunction`s in `Chat/Tools/`, executed via `.UseFunctionInvocation()`; Python
  runs through `Lokad.Lython` in a deny-all sandbox.
- **API versioning:** `Asp.Versioning.Http` with URL-segment versioning (`/v{version}/...`).
- **Serialization:** default minimal-API JSON (`JsonSerializerDefaults.Web`) → **camelCase**.

## Layout

```
backend/
  Procul.slnx                      # solution (references src/Procul.Api/Procul.Api.csproj)
  src/Procul.Api/
    Program.cs                     # host, DI (IChatClient, DbContext, versioning), route wiring
    Chat/
      Conversation.cs              # entity
      Message.cs                   # ConversationMessage entity
      MessageRole.cs               # enum + MessageRoleExtensions.ToChatRole() (namespace Procul.Api.Chat)
      Tools/
        AgentTools.cs              # AITool registry + system prompt (source of ChatOptions.Tools)
        TimeTool.cs                # get_current_time
        PythonSandbox.cs           # run_python via Lokad.Lython + DenyAllLythonHost
      V1/
        ChatEndpointsV1.cs         # minimal-API endpoints + route mapping
        ChatStreamServiceV1.cs     # shared conversation-turn streaming logic
        DataTypesV1.cs             # request/response/event DTOs for v1
    Infrastructure/DbContext.cs    # ProculDbContext + model config
    Versioning/                    # ApiVersions + AddProculApiVersioning
    Migrations/                    # EF Core migrations
    docker/docker-compose.yaml     # dev-only Postgres
    justfile                       # dev-compose-* / run-dev helpers
    Procul.Api.http                # manual request examples
```

Note the project file is `Procul.Api.csproj`; the assembly/namespace root is `Procul.Api`.

## Build / run / test

```bash
cd backend
dotnet build Procul.slnx            # builds the whole solution

cd src/Procul.Api
just run-dev                        # docker compose up (Postgres) + dotnet run
# or manually:
just dev-compose-up                 # start Postgres on :5432
dotnet run                          # listens on http://localhost:5010 (launchSettings)
```

- Dev Postgres container: `procul_postgres_dev` (db/user/pass = `procul`/`postgres`/`postgres`).
- Migrations are **not** applied automatically; run `dotnet ef database update` or the DB
  must already be migrated. Check with
  `docker exec procul_postgres_dev psql -U postgres -d procul -c '\dt'`.
- OpenAPI (dev only): `GET /openapi/v1.json`.

## Configuration

Loaded by `DotNetEnv.Env.Load()` at startup from `src/Procul.Api/.env` (gitignored):

- `ConnectionStrings__ChatContext` — Postgres connection string.
- `OPENROUTER_API_KEY`, `OPENROUTER_MODEL_SLUG` — read once at startup; app throws if missing.

`.env.example` documents the shape. **Do not commit `.env`.** Treat any key in it as live.

## API surface (v1)

Base: `/v{version}/conversations` (e.g. `/v1/conversations`).

| Method | Route | Result |
| --- | --- | --- |
| POST | `/` | **SSE** stream. Creates a conversation, streams the assistant reply. |
| GET | `/{conversationId:guid}` | JSON `ConversationV1` or 404. |
| GET | `/{conversationId:guid}/messages` | JSON message page (`limit` 1–100, `afterMessageId` cursor). |
| POST | `/{conversationId:guid}/messages` | **SSE** stream. Appends a user message, streams the reply. 404 if missing. |

## Conventions & patterns

- **Minimal APIs only.** Endpoints are static methods in `ChatEndpointsV1`, mapped in
  `MapChatV1`. Prefer `TypedResults.*` and typed result unions like
  `Results<Ok<T>, NotFound>` / `Results<..., ProblemHttpResult>`.
- **Versioned DTOs** live under `Chat/V1` and are suffixed `V1`. A future v2 should get its
  own folder and its own event/stream service rather than reusing v1 types.
- **SSE:** return `TypedResults.ServerSentEvents(IAsyncEnumerable<SseItem<ChatStreamEventV1>>)`
  (or the `IAsyncEnumerable<T>` overload). The response is `text/event-stream`, no `event:`
  name is emitted, and the event kind is carried by a `type` discriminator **inside the JSON
  payload** (e.g. `created`, `acknowledge`, `token`, `toolCall`, `toolResult`, `error`,
  `done`).
- **Streaming turn logic** lives once in `ChatStreamServiceV1.StreamAssistantReplyAsync`;
  both create and send delegate to it. Keep new streaming features there, not duplicated in
  endpoints.
- **Persistence:** user message is saved immediately, then the assistant reply after the
  stream completes. Do **not** hold a DB transaction open across the model call.
- **AI client:** `IChatClient` is registered as a singleton via `AddChatClient(...)`; inject
  it. Do not construct OpenAI clients per request.
- **Cursor pagination:** order by `CreatedAt DESC, Id DESC` and filter with a matching keyset
  predicate (see `GetConversationMessagesAsync`).

## Tools (agent function calling)

The model is given two tools, registered in `Chat/Tools/` and passed on every turn through
`ChatOptions.Tools`. `ChatStreamServiceV1.StreamAssistantReplyAsync` prepends
`AgentTools.SystemPrompt` as a `System` message and supplies the tools:

- `AgentTools.cs` — the `AITool` registry (`AgentTools.All`) and the system prompt.
- `TimeTool.cs` — `get_current_time`: current ISO-8601 time at a numeric UTC offset (named
  IANA zones are unreliable under `InvariantGlobalization`).
- `PythonSandbox.cs` — `run_python`: runs a short Python 3 script through `Lokad.Lython` and
  returns its captured stdout/stderr.

**`Lokad.Lython` 0.9.0** (MIT, pinned) is the Python runtime: pure managed C#, no native
dependencies, and contained by design. Scripts reach the outside world only through the
`ILythonHost` we supply, and `DenyAllLythonHost` grants nothing: the clock is real, but every
file/path/process operation throws `LythonHostCapabilityUnavailableException`, so
`open`/`os`/`pathlib`/`subprocess` fail explicitly. Runs are bounded by `MaxExecutionSteps`
(5M) plus a 5s cancellation deadline. The stdlib is a small allowlist (`math`, `statistics`,
`decimal`, `random`, `json`, `re`, `collections`, `itertools`, `functools`, `datetime`,
`time`, ...). Lython is a Python *subset*: unsupported constructs fail explicitly and the
error is fed back to the model, which can retry.

Tool call/result messages are **not persisted** (the schema stores only text + role), but tool
activity **is surfaced** in the SSE stream: the streaming turn logic scans each
`ChatResponseUpdate` for `FunctionCallContent`/`FunctionResultContent` and emits `toolCall`
(then `toolResult`, correlated by `callId`) events around the assistant's `token`s. The client
can therefore show which tools ran during a turn; a reloaded conversation only replays the
final assistant text.

## Gotchas (learned the hard way)

- **`yield return` is illegal inside a `try` that has a `catch`.** To convert a mid-stream
  failure into an event, wrap the source enumerable and catch around `MoveNextAsync` only —
  see `ChatStreamServiceV1.CatchToEvent`.
- **Polymorphic SSE serialization works without `[JsonDerivedType]`.** `ServerSentEventsResult<T>`
  falls back to the `object` type info when the runtime type is a derived type of the
  (abstract) `T`, so the abstract `ChatStreamEventV1` hierarchy serializes the derived record
  with camelCase and its `type` field. You do **not** need to annotate the hierarchy.
- **`Guid.CompareTo` translates** in EF Core 10 / Npgsql to a SQL comparison (`m."Id" < @id`),
  which is what makes the keyset cursor work. Both the filter and the `ORDER BY` run in SQL,
  so they stay consistent.
- **JSON is camelCase.** Request bodies must use camelCase (e.g. `initialMessage`), not
  snake_case. `Procul.Api.http` reflects this.
- **`MessageRole` is persisted as a `string`** (`.HasConversion<string>()`), so moving the
  enum between CLR namespaces does not affect the schema or migrations.
- **Keep `Procul.slnx` in sync** with the project file name; it once pointed at a
  non-existent `Procul.csproj` and broke `dotnet build Procul.slnx`.
- **No `save` = no persistence.** `AddDbContextPool` + EF change tracking still requires an
  explicit `SaveChangesAsync`; a committed transaction without a save persists nothing.
- **Tools do nothing unless function invocation is enabled.** `AddChatClient(...)` only
  registers the raw client; chain `.UseFunctionInvocation()` on its builder (see `Program.cs`)
  or the model can request tool calls that are silently never executed.
- **`UseFunctionInvocation()` still surfaces tool calls.** Although it runs the tool loop
  internally, the `ChatResponseUpdate`s it yields still carry the model's `FunctionCallContent`
  and the `FunctionResultContent`. `StreamTokens` reads those to emit the `toolCall`/
  `toolResult` SSE events. A tool result is boxed as a `JsonElement`, so `FormatResult`
  unwraps string values (otherwise they arrive JSON-quoted with escaped `+`).
