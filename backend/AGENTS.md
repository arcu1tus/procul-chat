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
- **MCP:** remote Model Context Protocol servers (Streamable HTTP + legacy SSE) configured in
  `config.jsonc`, connected by `Mcp/McpClientManager`; their tools join the built-ins each turn.
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
    Configuration/
      DurationParser.cs            # shared <number><unit> duration parsing (d/h/m/s)
    Mcp/
      McpOptions.cs                # PROCUL_CONFIG_PATH, timeouts, health interval, enabled flag
      ProculConfig.cs              # POCO: { McpServers: { name -> McpServerConfig } }
      McpServerConfig.cs           # { Type, Url, Headers, Enabled }
      McpConfigLoader.cs           # read + JSONC parse + ${ENV} expand + validate (fail fast)
      McpToolNaming.cs             # namespacing + sanitization + collision resolution
      McpClientManager.cs          # singleton IHostedService: connect, discover, reconnect, status
      McpServiceCollectionExtensions.cs  # AddProculMcp(configuration)
      V1/
        McpEndpointsV1.cs          # GET /v1/mcp/servers (authenticated) + reconnect
        DataTypesV1.cs             # response DTOs
    Infrastructure/
      DbContext.cs                 # ProculDbContext + model config
      DbContextExtensions.cs       # AddProculDbContext
    Cors/CorsExtensions.cs         # AddProculCors/UseProculCors (browser/web origin policy)
    Security/
      AuthOptions.cs               # PROCUL_API_PASSWORD + PROCUL_SESSION_LIFETIME (fail fast)
      PasswordVerifier.cs          # constant-time password check (SHA-256 + FixedTimeEquals)
      SessionTokenService.cs       # issues HS256 session JWTs (key derived from the password)
      AuthExtensions.cs            # AddProculAuth/UseProculAuth (JWT bearer + authorization)
      V1/
        AuthEndpointsV1.cs         # /v1/auth/session: exchange password -> token, probe
        DataTypesV1.cs             # request/response DTOs for the auth endpoints
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
- `PROCUL_API_PASSWORD` — the shared password protecting the whole API. **Required**: startup
  fails fast when it is unset/empty. The client exchanges it for a session token (see
  Authentication). Use a strong random value.
- `PROCUL_SESSION_LIFETIME` — how long an issued session token stays valid. Optional; defaults
  to `30d`. Accepts one or more `<number><unit>` segments with unit `d`/`h`/`m`/`s`
  (e.g. `12h`, `1h30m`); a malformed value fails startup.
- `CORS_ALLOWED_ORIGINS` — comma-separated browser origins allowed to call the API
  (e.g. `https://app.example.com`). In **development** only, when unset, any origin is allowed
  (the Flutter web dev server uses an ephemeral `localhost` port, so pinning an origin is
  impractical). In every other environment the policy allows **no** cross-origin request until
  this is set — there is no wildcard in production. A `*` or a malformed value makes startup
  fail fast. The API is cookie-less: clients send a bearer token (see Authentication), so CORS
  never enables `AllowCredentials`.
- `PROCUL_CONFIG_PATH` — path to the MCP config file (absolute or relative). Optional; defaults
  to `config.jsonc` next to the app. A missing *default* file disables MCP (info log); a missing
  *explicitly-set* path is fatal.
- `MCP_ENABLED` — master switch. Optional; defaults to `true`. When `false`, the config file is
  never read.
- `MCP_CONNECT_TIMEOUT` — per-server connect + tool-discovery budget. Optional; defaults to
  `15s`. Same duration syntax as `PROCUL_SESSION_LIFETIME` (see `Configuration/DurationParser.cs`).
- `MCP_HEALTH_INTERVAL` — background ping/reconnect cadence. Optional; defaults to `60s`.

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
  -e PROCUL_API_PASSWORD=... \
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

## Authentication

The whole `/v1` API is gated by a single shared password (`PROCUL_API_PASSWORD`). There are no
users and no token store.

- `POST /v1/auth/session` — body `{"password":"…"}`. Correct → `200 {"token":"…","expiresAt":"…"}`;
  wrong/empty → `401` (generic body, never says why). Unauthenticated.
- `GET /v1/auth/session` — authenticated probe: `204` when the bearer token is valid, else `401`.
- `GET /health` — unauthenticated liveness probe.
- Every `/v1/conversations` route requires `Authorization: Bearer <token>`.

The token is an **HS256 JWT** (`sub="procul"`, `iat`, `exp`) issued by `SessionTokenService`.
Its signing key is `SHA-256(password + fixed context)`, so **changing the password invalidates
every existing token** with no server-side state. Validation uses
`Microsoft.AspNetCore.Authentication.JwtBearer` with `ClockSkew = TimeSpan.Zero` (the `exp`
claim is honored exactly). `PasswordVerifier` compares candidate passwords in constant time
(SHA-256 both sides, then `FixedTimeEquals`) so timing leaks neither length nor prefix.

`UseProculAuth()` (`UseAuthentication`/`UseAuthorization`) runs **after** `UseProculCors()`, so
CORS preflight (`OPTIONS`) short-circuits before authorization and stays unauthenticated — the
browser flow is unchanged. `Authorization` is a normal header already covered by
`AllowAnyHeader()`.

## API surface (v1)

Base: `/v{version}/conversations` (e.g. `/v1/conversations`). All routes require a bearer token;
the auth and health routes do not (see Authentication).

| Method | Route | Result |
| --- | --- | --- |
| GET | `/health` | JSON `{"status":"healthy"}`. Unauthenticated. |
| POST | `/v{version}/auth/session` | Exchange the password for a session token. 200 or 401. Unauthenticated. |
| GET | `/v{version}/auth/session` | Authenticated probe: 204 if the token is valid, else 401. |
| GET | `/` | JSON `GetConversationsResponseV1`. All conversations, newest activity first. |
| POST | `/` | **SSE** stream. Creates a conversation, streams the assistant reply, then a `title` event. |
| GET | `/{conversationId:guid}` | JSON `ConversationV1` or 404. |
| PATCH | `/{conversationId:guid}` | Rename. Body `{"title":"..."}` (1–60 chars). `ConversationV1`, 400, or 404. |
| DELETE | `/{conversationId:guid}` | Deletes the conversation and its messages (cascade). 204 or 404. |
| GET | `/{conversationId:guid}/messages` | JSON message page (`limit` 1–100, `afterMessageId` cursor). |
| POST | `/{conversationId:guid}/messages` | **SSE** stream. Appends a user message, streams the reply. 404 if missing. |
| GET | `/v{version}/mcp/servers` | JSON `McpServersResponseV1`: live per-server status. Authenticated. No secrets. |
| POST | `/v{version}/mcp/servers/{name}/reconnect` | Force a reconnect. `McpReconnectResponseV1`; 404 if unknown. |

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

The model is given two built-in tools, registered in `Chat/Tools/`, plus every tool discovered
from the configured MCP servers (see below). All are passed on every turn through
`ChatOptions.Tools`. `ChatStreamServiceV1.StreamAssistantReplyAsync` prepends
`AgentTools.SystemPrompt + mcp.SystemPromptSuffix` as a `System` message and supplies
`MergeTools(mcp)`:

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

## MCP (remote tool servers)

The backend can call tools hosted by remote **Model Context Protocol** servers. Only remote
transports are supported — `http` (Streamable HTTP) and `sse` (legacy) — because the runtime
image is ASP.NET-only (no node/npx for stdio).

- **Config.** Servers are declared in `config.jsonc` (JSONC: comments + trailing commas), found
  at `PROCUL_CONFIG_PATH` or `config.jsonc` next to the app. `config.jsonc.example` is committed;
  the real file is git-ignored and bind-mounted read-only in the container. `McpConfigLoader`
  validates it and is **fail-fast**: malformed JSON, an unknown `type`, a missing `url`, a blank
  server name, a non-absolute URL, or an unresolved `${ENV_VAR}` all abort startup. An
  unreachable server is **not** fatal.
- **Secrets.** Header values (e.g. an `Authorization` bearer) live in `.env` and are referenced
  from the JSON as `${VAR}`. The loader resolves them from the process environment. Headers are
  never logged and never returned by the status endpoint.
- **`McpClientManager`** is a singleton `IHostedService` started before Kestrel serves traffic.
  It connects to every enabled server in parallel (each bounded by `MCP_CONNECT_TIMEOUT`),
  discovers tools, and logs one line per server. A background loop pings connected servers and
  reconnects the rest with backoff (`MCP_HEALTH_INTERVAL`). A dead server never blocks startup.
- **Tool naming.** `McpClientTool` derives from `AIFunction`, so `UseFunctionInvocation()` already
  dispatches it and the streaming/tool-event loop is unchanged. Names are `{server}__{tool}`
  (both segments sanitized to `[a-zA-Z0-9_-]`), truncated to 64 chars and suffixed `_2`, `_3`, …
  on collision. `McpToolNaming`/`McpToolNameAssigner` own this.
- **Status.** `GET /v1/mcp/servers` (authenticated) reports name/type/url/connected/toolCount/
  tools/lastError/lastConnectedAt. `POST /v1/mcp/servers/{name}/reconnect` forces a reconnect.
  There is no config hot-reload: a config change needs a restart (the loop only reconnects).

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
- **The app fails fast without `PROCUL_API_PASSWORD`.** Any test that boots the real app
  (`WebApplicationFactory<Program>`) must set it via
  `UseSetting("PROCUL_API_PASSWORD", …)`, or startup throws. The authenticated probe
  (`GET /v1/auth/session`) is the DB-free way to assert a token was accepted; a request to
  `/v1/conversations` would need Postgres.
- **MCP config is loaded at startup, not at DI time.** `McpServiceCollectionExtensions.AddProculMcp`
  only reads `McpOptions`; the file itself is read in `McpClientManager.StartAsync` (a hosted
  service). That keeps DI registration side-effect-free and means a bad config file still fails
  startup (a hosted-service start failure stops the host).
- **MCP failures must never leak a token.** `McpClientManager` logs only a concise status (e.g.
  `mcp[github]: failed — 401 Unauthorized`) and the status endpoint exposes name/type/url/tools
  only. If you add fields, keep headers out.
- **`McpClientTool` is an `AIFunction`.** No special-casing is needed in the streaming loop; a
  failed MCP call surfaces through the existing `FunctionResultContent.Exception` → `toolResult`
  error path. Only the *presentation* name changes (`WithName`); the underlying call still targets
  the server's real tool name.
- **MCP tool names must be OpenAI-legal.** `^[a-zA-Z0-9_-]{1,64}$` and unique across the
  built-ins and every server; `McpToolNameAssigner` enforces both. Don't hand-build names.
- **The MCP end-to-end tests host a real loopback server.** `McpTestServerHost` starts a tiny
  `ModelContextProtocol.AspNetCore` app on `127.0.0.1:0` (via `WebHostDefaults.ServerUrlsKey`,
  because `ConfigureWebHostBuilder` has no `UseUrls`), and the manager connects through it. The
  server builder must call `WithHttpTransport()` before `MapMcp`, or `MapMcp` throws.
