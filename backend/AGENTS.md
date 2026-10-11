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
  Procul.slnx                      # solution (references src/Procul.Api + tests/Procul.Api.Tests)
  .dockerignore                    # build-context excludes for the image (context root is backend/)
  src/Procul.Api/
    Program.cs                     # host + route wiring (DI lives in the extension files below)
    Dockerfile                     # multi-stage container build (build context: backend/)
    Chat/
      ChatServiceCollectionExtensions.cs  # AddProculChat: IChatClient + ChatStreamServiceV1
      Conversation.cs              # entity
      ConversationMessage.cs       # ConversationMessage entity
      MessageRole.cs               # enum + MessageRoleExtensions.ToChatRole() (namespace Procul.Api.Chat)
      Tools/
        AgentTools.cs              # AITool registry + system prompt (source of ChatOptions.Tools)
        TimeTool.cs                # get_current_time
        PythonSandbox.cs           # run_python via Lokad.Lython + DenyAllLythonHost
      V1/
        ChatEndpointsV1.cs         # minimal-API endpoints + route mapping
        ChatStreamServiceV1.cs     # conversation-turn streaming (create + reply + title)
        DataTypesV1.cs             # request/response DTOs for v1
        ChatStreamEventsV1.cs      # SSE event payloads + ChatStreamEventV1 hierarchy
    Infrastructure/
      DbContext.cs                 # ProculDbContext + model config
      DbContextExtensions.cs       # AddProculDbContext
    Cors/CorsExtensions.cs         # AddProculCors/UseProculCors (browser/web origin policy)
    Versioning/                    # ApiVersions + AddProculApiVersioning
    Migrations/                    # EF Core migrations
    docker/docker-compose.yaml     # dev-only Postgres
    justfile                       # dev-compose-* / run-dev helpers
    Procul.Api.http                # manual request examples
  tests/Procul.Api.Tests/          # xUnit unit + integration tests (no DB/network needed)
```

Note the project file is `Procul.Api.csproj`; the assembly/namespace root is `Procul.Api`.

## Build / run / test

```bash
cd backend
dotnet build Procul.slnx            # builds the whole solution
dotnet test  Procul.slnx            # unit + integration tests (no DB or network required)

cd src/Procul.Api
just run-dev                        # docker compose up (Postgres) + dotnet run
# or manually:
just dev-compose-up                 # start Postgres on :5432
dotnet run                          # listens on http://localhost:5010 (launchSettings)
```

- Dev Postgres container: `procul_postgres_dev` (db/user/pass = `procul`/`postgres`/`postgres`).
- Migrations are applied automatically at startup: `Program.cs` calls
  `DbContextExtensions.ApplyProculMigrationsAsync`, which runs `Database.MigrateAsync()` —
  creating the database if needed and applying any pending migrations (idempotent). It is
  skipped only when `ConnectionStrings:ChatContext` is unset, so the integration tests still
  boot with no database. Check with
  `docker exec procul_postgres_dev psql -U postgres -d procul -c '\dt'`.
- OpenAPI (dev only): `GET /openapi/v1.json`.

## Configuration

Loaded by `DotNetEnv.Env.Load()` at startup from `src/Procul.Api/.env` (gitignored):

- `ConnectionStrings__ChatContext` — Postgres connection string.
- `OPENROUTER_API_KEY`, `OPENROUTER_MODEL_SLUG` — read once at startup; app throws if missing.
- `CORS_ALLOWED_ORIGINS` — comma-separated browser origins allowed to call the API
  (e.g. `https://app.example.com`). In **development** only, when unset, any origin is allowed
  (the Flutter web dev server uses an ephemeral `localhost` port, so pinning an origin is
  impractical). In every other environment the policy allows **no** cross-origin request until
  this is set — there is no wildcard in production. A `*` or a malformed value makes startup
  fail fast. The API is unauthenticated and cookie-less, so no credentials travel.

The app manages its own schema: on startup it applies pending EF Core migrations (see
Build / run / test). There is no flag for this — it happens whenever a database is configured.

`.env.example` documents the shape. **Do not commit `.env`.** Treat any key in it as live.

## Container image & CI

The backend ships as a container image (`src/Procul.Api/Dockerfile`, **build context is
`backend/`** so the restore/publish paths are `src/Procul.Api/...`):

```bash
docker build -f backend/src/Procul.Api/Dockerfile -t procul-api backend
docker run --rm -p 8080:8080 \
  -e OPENROUTER_API_KEY=... -e OPENROUTER_MODEL_SLUG=... \
  -e ConnectionStrings__ChatContext="..." -e CORS_ALLOWED_ORIGINS=https://app.example.com \
  procul-api
```

- Multi-stage: .NET 10 **SDK** builds/publishes; the final stage is the **ASP.NET Core
  runtime** only, running as the non-root `app` user on port `8080` (`ASPNETCORE_URLS`).
- **Caching:** the `.csproj` is copied alone before `dotnet restore`, so the restore layer is
  reused until dependencies change; NuGet packages live in a BuildKit
  `--mount=type=cache,target=/root/.nuget/packages` mount, and the workflow exports the Docker
  layer cache with `cache-from/to: type=gha`.
- `backend/.dockerignore` (context root) keeps `bin/`, `obj/`, and — importantly — `.env` out
  of the build context. The image is environment-agnostic; config is injected at run time.
- GitHub Actions: `.github/workflows/ci.yml` builds/tests on pushes to `main` and PRs;
  `.github/workflows/publish-backend-image.yml` tests and pushes
  `ghcr.io/<owner>/<repo>/backend-api` on `v*` tags (via `GITHUB_TOKEN`, `packages: write`).

## API surface (v1)

Base: `/v{version}/conversations` (e.g. `/v1/conversations`).

| Method | Route | Result |
| --- | --- | --- |
| GET | `/` | JSON `GetConversationsResponseV1`. All conversations, newest activity first. |
| POST | `/` | **SSE** stream. Creates a conversation, streams the assistant reply, then a `title` event. |
| GET | `/{conversationId:guid}` | JSON `ConversationV1` or 404. |
| PATCH | `/{conversationId:guid}` | Rename. Body `{"title":"..."}` (1–60 chars). `ConversationV1`, 400, or 404. |
| DELETE | `/{conversationId:guid}` | Deletes the conversation and its messages (cascade). 204 or 404. |
| GET | `/{conversationId:guid}/messages` | JSON message page (`limit` 1–100, `afterMessageId` cursor). |
| POST | `/{conversationId:guid}/messages` | **SSE** stream. Appends a user message, streams the reply. 404 if missing. |

**Conversation titles.** A conversation starts with a placeholder title (the first line of the
initial message, truncated). On `POST /` the backend fires a *second*, tiny model call
(`ChatStreamServiceV1.GenerateTitleAsync`, capped at `TitleOptions` = 24 output tokens, no
tools, 8s timeout) **concurrently** with the reply, then emits a `title` event and persists
the result. The title call only produces a string — it never touches the `DbContext`, so it
can run alongside the reply stream without sharing a context; the write happens after the
stream completes. If it fails/times out, `FallbackTitle` is used. Rename/delete do not change
`UpdatedAt`; only new messages do.

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
- **Streaming turn logic** lives once in `ChatStreamServiceV1`. `StreamAssistantReplyAsync`
  is the shared reply turn; create wraps it with `StreamNewConversationAsync` (which emits
  `created` and the trailing `title`), and send calls it directly. Keep new streaming
  features there, not duplicated in endpoints.
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
  registers the raw client; chain `.UseFunctionInvocation()` on its builder (see
  `Chat/ChatServiceCollectionExtensions.cs`) or the model can request tool calls that are
  silently never executed.
- **`UseFunctionInvocation()` still surfaces tool calls.** Although it runs the tool loop
  internally, the `ChatResponseUpdate`s it yields still carry the model's `FunctionCallContent`
  and the `FunctionResultContent`. `StreamTokens` reads those to emit the `toolCall`/
  `toolResult` SSE events. A tool result is boxed as a `JsonElement`, so `FormatResult`
  unwraps string values (otherwise they arrive JSON-quoted with escaped `+`).
- **Browser clients need CORS; native ones do not.** `Cors/CorsExtensions.cs` registers the
  `ProculCors` policy and `Program.cs` calls `app.UseProculCors()` before the endpoints. Without
  it, `flutter run -d chrome` fails its preflight before a request ever reaches a handler.
  `application/json` bodies trigger a preflight, so `AllowAnyHeader()`/`AllowAnyMethod()` are
  required for the POST/PATCH/DELETE verbs. The policy must stay registered through the
  `CreateSlimBuilder` path (it does not add CORS implicitly). `UseProculCors` also logs the
  resolved origins and warns when production has none configured.
- **CORS origins are validated and fail fast.** `CorsExtensions.ParseOrigins` rejects `*`,
  non-absolute values, and origins with a path, then normalizes the trailing slash. It runs both
  at registration and at `UseProculCors()`, so a bad `CORS_ALLOWED_ORIGINS` crashes startup
  rather than silently blocking (or, worse, over-allowing) clients.
- **The test project pins EF Core.** `Microsoft.EntityFrameworkCore.Design` is
  `PrivateAssets=all` on the API, so it does not flow to `Procul.Api.Tests`, while Npgsql pulls
  an older EF Core. The test project references `Microsoft.EntityFrameworkCore.Relational`
  10.0.12 directly to keep its compile-time view in sync with the API assembly (otherwise
  `CS1705`).
- **Tests reach internals via `InternalsVisibleTo`.** `Procul.Api.csproj` exposes internals to
  `Procul.Api.Tests`, and `Program.cs` ends with a `public partial class Program` so the
  integration tests can boot the real app with `WebApplicationFactory<Program>`. CORS preflight
  tests need no database; keep it that way (the app connects to Postgres lazily).
