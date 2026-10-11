# AGENTS.md — Procul chat backend

> **Keep this file up to date.** If you change the structure, conventions, commands, or
> gotchas described here, update this file in the same change. A stale AGENTS.md is worse
> than none. When in doubt, add a short note rather than leaving it wrong.

## What this is

Backend for a chat app ("Procul"). It exposes a versioned minimal-API HTTP surface that
creates conversations, streams assistant replies over Server-Sent Events (SSE), and reads
message history. Persistence is PostgreSQL via EF Core; the LLM is called through
`Microsoft.Extensions.AI` against one or more configured OpenAI-compatible providers.

- **Framework:** .NET 10 (`net10.0`), ASP.NET Core minimal APIs, `CreateSlimBuilder`.
- **Config:** `config.jsonc` is the single source of truth (JSONC + JSON Schema + `${ENV}`
  secrets); `.env` holds secrets only. See **Configuration**.
- **DB:** PostgreSQL + `Npgsql.EntityFrameworkCore.PostgreSQL`, `AddDbContextPool`.
- **AI:** `Microsoft.Extensions.AI` + `Microsoft.Extensions.AI.OpenAI`; one `IChatClient` per
  configured model (`Chat/ChatModelRegistry.cs`), selected per conversation.
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
      ChatServiceCollectionExtensions.cs  # AddProculChat: registry + turn service + catalog/health
      ChatModelDefinition.cs       # validated model entry (slug, provider, capabilities, flags)
      ChatModelRegistry.cs         # one IChatClient per configured model + slug resolution
      Conversation.cs              # entity (incl. the per-conversation Model slug)
      ConversationMessage.cs       # ConversationMessage entity
      MessageRole.cs               # enum + MessageRoleExtensions.ToChatRole() (namespace Procul.Api.Chat)
      TurnUsage.cs                 # entity: one model call's token usage (TurnKind Chat | Title)
      TurnUsageTotals.cs           # mutable accumulator for a turn's UsageContent payloads
      Models/
        ModelUsageTracker.cs       # last-used timestamp per slug (drives the idle re-probe)
        ModelCapabilityDiscovery.cs# OpenRouter /models capability discovery (cached, non-fatal)
        ModelCatalogService.cs     # IHostedService: startup + idle health probes, on-demand checks
        ModelHealthOptions.cs      # modelHealth.* (enabled, interval, timeout, prompt, maxTokens)
      Tools/
        AgentTools.cs              # AITool registry + system prompt (source of ChatOptions.Tools)
        TimeTool.cs                # get_current_time
        PythonSandbox.cs           # run_python via Lokad.Lython + DenyAllLythonHost
      V1/
        ChatEndpointsV1.cs         # minimal-API endpoints + route mapping
        ChatStreamServiceV1.cs     # conversation-turn streaming (create + reply + title)
        DataTypesV1.cs             # request/response DTOs for v1
        ModelEndpointsV1.cs        # GET /v1/models + POST .../check (single + all)
        ChatStreamEventsV1.cs      # SSE event payloads + ChatStreamEventV1 hierarchy
        TitleGenerationResult.cs   # title + its token usage (returned by GenerateTitleAsync)
    Attachments/
      Attachment.cs                # Attachment + AttachmentBlob entities (metadata in Postgres)
      IAttachmentStore.cs          # Put/OpenRead/Delete abstraction (+ Kind) for the bytes
      PostgresAttachmentStore.cs   # default: the AttachmentBlobs bytea table
      S3AttachmentStore.cs         # AWSSDK.S3 (MinIO/S3-compatible via serviceUrl + forcePathStyle)
      AttachmentValidation.cs      # size/wildcard content-type checks + filename sanitize
      AttachmentContentBuilder.cs  # attachment -> AIContent mapping + capability gating (pure)
      AttachmentGate.cs            # load/validate/capability-gate the ids on a send
      AttachmentServiceCollectionExtensions.cs  # AddProculAttachments(config): pick the store
      V1/
        AttachmentEndpointsV1.cs   # POST/GET/DELETE /v1/attachments
        DataTypesV1.cs             # AttachmentV1 DTO
    Configuration/
      ProculConfig.cs              # root POCO for config.jsonc (server/db/models/mcp/...)
      ProculConfigLoader.cs        # locate + JSONC parse + schema validate + ${ENV} + domain validate
      DurationParser.cs            # shared <number><unit> duration parsing (d/h/m/s)
      AttachmentOptions.cs         # attachments.* derived options
    Mcp/
      McpOptions.cs                # mcp.* (enabled, connect timeout, health interval)
      McpServerConfig.cs           # { Type, Url, Headers, Enabled }
      McpConfigLoader.cs           # validate the parsed ProculConfig.McpServers (fail fast)
      McpToolNaming.cs             # namespacing + sanitization + collision resolution
      McpClientManager.cs          # singleton IHostedService: connect, discover, reconnect, status
      McpServiceCollectionExtensions.cs  # AddProculMcp(config)
      V1/
        McpEndpointsV1.cs          # GET /v1/mcp/servers (authenticated) + reconnect
        DataTypesV1.cs             # response DTOs
    Usage/
      UsageAggregator.cs           # pure UTC-day bucketing + totals (no Postgres needed)
      V1/
        UsageEndpointsV1.cs        # GET /v1/usage ; GET /v1/usage/conversations/{id}
        DataTypesV1.cs             # usage response DTOs (camelCase; tokens only)
    Infrastructure/
      DbContext.cs                 # ProculDbContext + model config
      DbContextExtensions.cs       # AddProculDbContext(config)
    Cors/
      CorsOptions.cs               # server.corsAllowedOrigins (validated, normalized)
      CorsExtensions.cs            # AddProculCors/UseProculCors (browser/web origin policy)
    Security/
      AuthOptions.cs               # PROCUL_API_PASSWORD (secret) + server.sessionLifetime (fail fast)
      PasswordVerifier.cs          # constant-time password check (SHA-256 + FixedTimeEquals)
      SessionTokenService.cs       # issues HS256 session JWTs (key derived from the password)
      AuthExtensions.cs            # AddProculAuth/UseProculAuth (JWT bearer + authorization)
      V1/
        AuthEndpointsV1.cs         # /v1/auth/session: exchange password -> token, probe
        DataTypesV1.cs             # request/response DTOs for the auth endpoints
    Versioning/                    # ApiVersions + AddProculApiVersioning
    Migrations/                    # EF Core migrations
    config.jsonc.example           # committed example config (the source of truth; real file gitignored)
    config.schema.json             # JSON Schema for config.jsonc (validated at startup + copied out)
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
  skipped only when `database.connectionString` is unset, so the integration tests still
  boot with no database. Check with
  `docker exec procul_postgres_dev psql -U postgres -d procul -c '\dt'`.
- OpenAPI (dev only): `GET /openapi/v1.json`.

## Configuration

**`config.jsonc` is the single source of truth for the backend.** It is loaded exactly once at
startup (`Program.cs` → `Configuration/ProculConfigLoader.Load`), before any DI wiring, and a
missing or invalid file is fatal. `.env` is demoted to a **secrets scratchpad**: `config.jsonc`
references environment variables as `${VAR}` and the loader resolves them from the process
environment (populated from `.env` by `DotNetEnv`). An unresolved reference names the variable.

The loader pipeline is: locate the file → parse JSONC (comments + trailing commas) → validate
against `config.schema.json` (JsonSchema.Net) → deserialize → expand every `${VAR}` → fail-fast
domain validation (≥1 model, exactly one default, unique slugs, absolute http(s) `baseUrl`, known
provider/capabilities, `attachments.storage` in `{postgres,s3}`, durations, `titleModel`
references a configured slug). Sections:

- `server.corsAllowedOrigins[]` — browser origins allowed to call the API (was `CORS_ALLOWED_ORIGINS`).
  In **development** only, an empty list allows any origin (the Flutter web dev server uses an
  ephemeral `localhost` port). Elsewhere there is no wildcard; a `*` or malformed value fails
  startup. The API is cookie-less (bearer token), so CORS never enables `AllowCredentials`.
- `server.sessionLifetime` — session-token lifetime (was `PROCUL_SESSION_LIFETIME`). Default `30d`.
- `database.connectionString` — Postgres connection string (was `ConnectionStrings__ChatContext`).
  Unset means "no database" (integration tests boot this way).
- `attachments.*` — upload storage (`storage` selects the Postgres or S3 byte store), size limit,
  allowed content types, `resendHistory`, and `textInlineMaxBytes`; plus the `s3` connection
  settings (`bucket`/`region`/`serviceUrl`/`forcePathStyle`/`accessKey`/`secretKey`).
- `models[]` — one or more chat models (replaces `OPENROUTER_MODEL_SLUG`/`OPENROUTER_API_KEY`);
  see **Multi-model registry** below.
- `titleModel` — optional slug used for the title call; defaults to the conversation's model.
- `modelHealth.*` — probe enable/interval/timeout/prompt (see **Model catalog & health**).
- `mcp.*` + `mcpServers` — MCP settings and servers (was `MCP_ENABLED`/`MCP_CONNECT_TIMEOUT`/
  `MCP_HEALTH_INTERVAL` and the old config file).

Two environment variables remain environment-only:

- `PROCUL_CONFIG_PATH` — path to `config.jsonc` (absolute or relative). Optional; defaults to
  `config.jsonc` next to the app. A missing file is **always** fatal now (models are required).
- `PROCUL_API_PASSWORD` — the shared password protecting the whole API. **Required**: startup
  fails fast when it is unset/empty. It is never stored in `config.jsonc`.

The app manages its own schema: on startup it applies pending EF Core migrations (see
Build / run / test). There is no flag for this — it happens whenever a database is configured.

`.env.example` documents the secrets only. **Do not commit `.env`.** Treat any key in it as live.

> **Design-time migrations:** because `Program.cs` loads the config before building the host,
> `dotnet ef migrations add …` also needs a valid config. Set `PROCUL_CONFIG_PATH` (and
> `PROCUL_API_PASSWORD`) when running EF tooling, e.g.
> `PROCUL_CONFIG_PATH=/tmp/config.jsonc PROCUL_API_PASSWORD=x dotnet ef migrations add Foo`.

## Container image & CI

The backend ships as a container image (`src/Procul.Api/Dockerfile`, **build context is
`backend/`** so the restore/publish paths are `src/Procul.Api/...`):

```bash
docker build -f backend/src/Procul.Api/Dockerfile -t procul-api backend
docker run --rm -p 8080:8080 \
  -e PROCUL_API_PASSWORD=... \
  -e OPENROUTER_KEY=sk-or-v1-... \
  -e DB_CONNECTION_STRING="Host=...;Port=5432;Database=procul;Username=...;Password=..." \
  -v ./config.jsonc:/app/config.jsonc:ro \
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
| POST | `/` | **SSE** stream. Creates a conversation, streams the assistant reply, then a `title` event. Body may carry `attachmentIds`. |
| GET | `/{conversationId:guid}` | JSON `ConversationV1` or 404. |
| PATCH | `/{conversationId:guid}` | Rename. Body `{"title":"..."}` (1–60 chars). `ConversationV1`, 400, or 404. |
| PUT | `/{conversationId:guid}/model` | Set the conversation's model. Body `{"model":"slug"}`. `ConversationV1`, 400 (unknown slug), or 404. |
| DELETE | `/{conversationId:guid}` | Deletes the conversation and its messages (cascade). 204 or 404. |
| GET | `/{conversationId:guid}/messages` | JSON message page (`limit` 1–100, `afterMessageId` cursor). |
| POST | `/{conversationId:guid}/messages` | **SSE** stream. Appends a user message, streams the reply. Body may carry `attachmentIds`. 404 if missing. |
| POST | `/v{version}/attachments` | Multipart upload (`file` field) → `201 AttachmentV1`. `400` disallowed type, `413` too large. |
| GET | `/v{version}/attachments/{id:guid}` | The raw bytes, with the stored `Content-Type` and an inline `Content-Disposition`; `404` if unknown. |
| DELETE | `/v{version}/attachments/{id:guid}` | `204`, idempotent (unknown id is also `204`). |
| GET | `/v{version}/models` | JSON `GetModelsResponseV1`: `defaultModel` + every model with capabilities + live health. No secrets. |
| POST | `/v{version}/models/check` | Re-probe every health-checked model. `GetModelsResponseV1`. |
| POST | `/v{version}/models/{slug}/check` | Re-probe one model. `ModelV1`; 404 if unknown. (`{slug}` may contain `/`.) |
| GET | `/v{version}/mcp/servers` | JSON `McpServersResponseV1`: live per-server status. Authenticated. No secrets. |
| POST | `/v{version}/mcp/servers/{name}/reconnect` | Force a reconnect. `McpReconnectResponseV1`; 404 if unknown. |
| GET | `/v{version}/usage` | JSON `GetUsageResponseV1`: lifetime totals + per-UTC-day series + per-model breakdown (`days` 1–366, default 30). |
| GET | `/v{version}/usage/conversations/{conversationId:guid}` | JSON `UsageTotalsV1`: all-time totals for one conversation. |

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
  payload** (e.g. `created`, `acknowledge`, `token`, `toolCall`, `toolResult`, `usage`,
  `error`, `done`).
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

## Token usage

Every model call the backend makes records its token usage so it survives restarts, and the
client can show a per-conversation counter and a dashboard. There is **no dollar-cost
estimate** — tokens only, bucketed by **UTC** calendar day.

- **Entity.** `Chat/TurnUsage.cs`: one row per model call, with `Kind` (`TurnKind.Chat` for the
  reply, `TurnKind.Title` for the concurrent title call), the `Model` slug, and
  input/output/cached/total counts. Registered in `ProculDbContext` with a cascade delete from
  the conversation and indexes on `ConversationId`/`CreatedAt`.
- **Capture seam.** In `ChatStreamServiceV1.StreamTokens`, a `case UsageContent usageContent:`
  feeds a `TurnUsageTotals` accumulator. Because `UseFunctionInvocation()` can make several
  underlying model calls, the payloads are **summed**, not replaced; a single `usage` SSE event
  is emitted just before `done` when any usage was seen, and the reply's total is persisted as a
  `TurnKind.Chat` row in the same save as the assistant message. The title call's
  `ChatResponse.Usage` is persisted as a `TurnKind.Title` row (`GenerateTitleAsync` returns a
  `TitleGenerationResult` carrying it).
- **Model slug.** Each row records the slug of the model that produced it: `ChatStreamServiceV1`
  resolves the conversation's `Model` (falling back to `ChatModelRegistry.Default`) and passes
  `definition.Slug` to `TurnUsageTotals.ToTurnUsage`.
- **Aggregation.** `Usage/UsageAggregator.cs` is a pure function over `TurnUsage` rows: it
  buckets by UTC day, zero-fills every day in the window, and totals per model — kept in C# so
  it is testable without Postgres.
- **Endpoints.** `GET /v{version}/usage?days=` (lifetime totals + per-day series + per-model
  breakdown; `days` 1–366, default 30) and
  `GET /v{version}/usage/conversations/{id}` (all-time totals for one conversation). Both are
  authenticated like the rest of `/v1`.

## Attachments

Users can attach files to a message. Metadata (`Attachments/Attachment.cs`) always lives in
PostgreSQL; the **bytes** go to the store selected by `attachments.storage`:

- `PostgresAttachmentStore` (default) — a separate `AttachmentBlobs` table (`AttachmentId` PK,
  `Data bytea`) so metadata queries never drag blobs.
- `S3AttachmentStore` — `AWSSDK.S3`, with `AmazonS3Config { ServiceURL, ForcePathStyle }` when
  `serviceUrl` is set (MinIO/S3-compatible); credentials from `accessKey`/`secretKey` or the
  default chain. It talks to a thin internal `IS3Operations` seam so tests never touch S3.

**Store abstraction.** `IAttachmentStore.PutAsync(Attachment, Stream, ct)` returns the
`StorageKey`; `OpenReadAsync`/`DeleteAsync` are by key (delete is best-effort and idempotent).
`AddProculAttachments(config)` registers the implementation matching `attachments.storage`.
`PutAsync` takes the `Attachment` (not just a stream) because the Postgres store's blob row has
a foreign key to it — the endpoint adds the metadata row first so the FK is satisfied.

**Endpoints** (`Attachments/V1/AttachmentEndpointsV1.cs`, group `/v{version}/attachments`,
mapped next to `Mcp`/`Usage` in `Program.cs`): `POST /` (multipart `file`) validates size
(`413`) and content type against `allowedContentTypes` (wildcards like `image/*`; `400`),
hashes, stores, and returns `AttachmentV1`; `GET /{id}` streams the bytes with an inline
`Content-Disposition`; `DELETE /{id}` is `204`/idempotent. `MapPost` calls `DisableAntiforgery()`
— the API is bearer-token and cookie-less, so there is no CSRF surface. `Program.cs` raises
Kestrel's `MaxRequestBodySize` to `maxFileSizeBytes + 1 MiB` so multipart uploads reach the
handler (the `413` decision is the handler's, not Kestrel's).

**Sending with a message.** `CreateConversationRequestV1`/`SendMessageRequestV1` carry optional
`AttachmentIds`; `ConversationMessageV1` carries the attached files (empty for assistant/tool).
`ChatEndpointsV1` runs `AttachmentGate` (load the rows, 400 on unknown/already-attached ids),
then `ChatStreamServiceV1` attaches them to the persisted user message and builds the content
parts. `resendHistory: false` (default) means only the current user turn carries the bytes;
earlier turns with attachments contribute `AttachmentContentBuilder.HistoryNote(...)`.

**Content mapping** (`AttachmentContentBuilder`, pure + unit-tested):

| Type | Capability needed | Produced content |
| ---- | ----------------- | ---------------- |
| `image/*` | `image` | `DataContent(bytes, type)` → image part |
| `application/pdf` | `file`/`pdf` | `DataContent(bytes, "application/pdf") { Name }` → file part |
| `audio/mpeg`, `audio/mp3`, `audio/wav`, `audio/x-wav`, `audio/wave` | `audio` | `DataContent` → input-audio part |
| `text/*` | — (always) | `TextContent("--- file: name ---\n" + utf8)`, capped at `textInlineMaxBytes` |
| video / anything else | — | not sent: `TextContent("[Attached file: … — not sent to this model]")` |

The **capability gate is the backend's job** (`AttachmentContentBuilder.IsSupported`): a type the
model cannot read is a `400` naming the file and the missing capability. Video (and unknown
types) are deliberately *not* gated — the OpenAI adapter drops them for every model, so they are
stored + rendered but only ever contribute a placeholder.

## Multi-model registry

`config.jsonc` declares one or more `models[]`; `ChatModelRegistry` (singleton) builds **one
`IChatClient` per model** (`new OpenAI.Chat.ChatClient(model: slug, credential: ApiKeyCredential,
options: Endpoint = baseUrl).AsIChatClient().AsBuilder().UseFunctionInvocation().Build()`) and owns
them for the app lifetime. It replaces the old single-model `ChatModelOptions`. Key members:
`All`, `Default`, `Get(slug)`, `GetClient(slug)`, `TryResolve(slug, out def)` (unknown/null →
default), `ResolveOrDefault(slug)` (logs a warning when a stored slug is gone).

- **Per-conversation selection.** `Conversation.Model` (nullable, `varchar(256)`, migration
  `AddConversationModel`) remembers the model. `POST /conversations` accepts an optional `model`
  (validated → 400 on unknown), `PUT /conversations/{id}/model` changes it, and every turn uses
  the conversation's model (stale/unknown → default with a warning). `ConversationV1.Model`
  echoes it everywhere a conversation is returned.
- **Title model.** The title call uses `config.titleModel` when set, else the conversation's model.
- **`ChatModelDefinition`** carries `Slug`, `Name`, `Description`, `BaseUrl`, `ApiKey`,
  `Provider` (`OpenRouter | OpenAiCompatible`), `DeclaredCapabilities` (a set of
  `ModelInputModality`), `IsDefault`, `HealthCheck`, `DiscoverCapabilities`, `MaxOutputTokens?`.
  The provider is inferred from the base URL when omitted (`openrouter.ai` → OpenRouter).

## Model catalog & health

`Chat/Models/` adds three singletons wired by `AddProculChat`:

- **`ModelUsageTracker`** — last-used timestamp per slug. `ChatStreamServiceV1` calls
  `RecordUse(slug)` after every real reply and title call.
- **`ModelCapabilityDiscovery`** — for an OpenRouter model (or any model with
  `discoverCapabilities: true`) it `GET`s `{baseUrl}/models`, parses both the `{data:[...]}` and
  bare-array shapes, matches by `id`/`canonical_slug`, and reads `architecture.input_modalities` /
  `output_modalities` + `supported_parameters`. Best-effort (cached; a non-200 or failure falls
  back to declared capabilities).
- **`ModelCatalogService`** (`IHostedService`, started before Kestrel) — at startup it discovers
  capabilities and probes each model once unless `healthCheck: false`; then a background loop
  every `modelHealth.interval` (default `30m`) re-probes **only** models with no real traffic in
  the window (`ModelUsageTracker.UsedWithin`). The probe is a tiny `GetResponseAsync` capped at
  `modelHealth.maxOutputTokens` with a `modelHealth.timeout` budget; failures are never fatal.
  `CheckAsync(slug, source)` / `CheckAllAsync(source)` back the on-demand endpoints;
  `GetCapabilities` resolves discovered ∪ declared (text is the fallback), `GetHealth` returns the
  per-slug snapshot. `modelHealth.enabled: false` disables the whole service.

`GET /v1/models` returns `defaultModel` + each `ModelV1(slug, name, description, provider,
isDefault, capabilities { input[], output[] }, health { status, lastCheckedAt, latencyMs,
lastError, lastUsedAt, source })` — **never** the API key. `POST /v1/models/check` and
`POST /v1/models/{slug}/check` re-probe (the latter 404s on an unknown slug). Slugs can contain
`/`, so the route is a catch-all (`/{**rest}`) parsed in `ModelEndpointsV1`.

## MCP (remote tool servers)

The backend can call tools hosted by remote **Model Context Protocol** servers. Only remote
transports are supported — `http` (Streamable HTTP) and `sse` (legacy) — because the runtime
image is ASP.NET-only (no node/npx for stdio).

- **Config.** Servers are declared under `mcpServers` in `config.jsonc` (the same file as the
  rest of the backend config; JSONC: comments + trailing commas). The shared `ProculConfigLoader`
  parses and `${ENV}`-expands it; `McpConfigLoader` then validates the parsed
  `ProculConfig.McpServers` and is **fail-fast**: an unknown `type`, a missing `url`, a blank
  server name, a non-absolute URL, or an unresolved `${ENV_VAR}` all abort startup. An
  unreachable server is **not** fatal. `McpClientManager` receives the servers from the injected
  `ProculConfig`.
- **Secrets.** Header values (e.g. an `Authorization` bearer) live in `.env` and are referenced
  from the JSON as `${VAR}`. The loader resolves them from the process environment. Headers are
  never logged and never returned by the status endpoint.
- **`McpClientManager`** is a singleton `IHostedService` started before Kestrel serves traffic.
  It connects to every enabled server in parallel (each bounded by `mcp.connectTimeout`),
  discovers tools, and logs one line per server. A background loop pings connected servers and
  reconnects the rest with backoff (`mcp.healthInterval`). A dead server never blocks startup.
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
- **CORS origins are validated and fail fast.** `CorsOptions.ParseOrigins` rejects `*`,
  non-absolute values, and origins with a path, then normalizes the trailing slash. It runs at
  registration, so a bad `server.corsAllowedOrigins` crashes startup rather than silently
  blocking (or, worse, over-allowing) clients.
- **`config.jsonc` is required at runtime.** `Program.cs` loads it before DI wiring; there is no
  "test host" bypass. Integration tests write a temp file (`Support/TestConfig`) and set
  `PROCUL_CONFIG_PATH`. A missing file, a schema violation, an unresolved `${VAR}`, or a domain
  error all abort startup.
- **`dotnet ef` needs a valid config too.** Because the config is loaded in `Program.cs`,
  design-time commands run it. Set `PROCUL_CONFIG_PATH` and `PROCUL_API_PASSWORD` when running
  `dotnet ef migrations …` (see Configuration).
- **Model slugs can contain `/`.** A plain `{slug}` route segment cannot capture `vendor/model`,
  and a catch-all must be the final segment, so `ModelEndpointsV1` maps `POST /models/{**rest}`
  and parses `check` (all) vs `{slug}/check` (one). Keep that in mind if you add model routes.
- **The test project pins EF Core.** `Microsoft.EntityFrameworkCore.Design` is
  `PrivateAssets=all` on the API, so it does not flow to `Procul.Api.Tests`, while Npgsql pulls
  an older EF Core. The test project references `Microsoft.EntityFrameworkCore.Relational`
  10.0.12 directly to keep its compile-time view in sync with the API assembly (otherwise
  `CS1705`). It also references `Microsoft.EntityFrameworkCore.InMemory` (10.0.12): the pipeline
  integration tests register it in place of Npgsql (leaving the connection string unset, so
  migrations are skipped) and seed rows directly.
- **The in-memory provider does not support `ExecuteUpdateAsync`.** `ChatStreamServiceV1` bumps
  `Conversation.UpdatedAt` by mutating the tracked entity (not `ExecuteUpdateAsync`) so the turn
  is exercisable in tests. Keep it that way, or `ModelSelectionTests` breaks.
- **Tests reach internals via `InternalsVisibleTo`.** `Procul.Api.csproj` exposes internals to
  `Procul.Api.Tests`, and `Program.cs` ends with a `public partial class Program` so the
  integration tests can boot the real app with `WebApplicationFactory<Program>`. CORS preflight
  tests need no database; keep it that way (the app connects to Postgres lazily).
- **The app fails fast without `PROCUL_API_PASSWORD`.** Any test that boots the real app
  (`WebApplicationFactory<Program>`) must set it via
  `UseSetting("PROCUL_API_PASSWORD", …)` and a config via `PROCUL_CONFIG_PATH`, or startup throws.
  The authenticated probe (`GET /v1/auth/session`) is the DB-free way to assert a token was
  accepted; a request to `/v1/conversations` would need Postgres.
- **MCP config is validated at startup, not at DI time.** `AddProculMcp` only derives
  `McpOptions`; `McpConfigLoader.Load(ProculConfig.McpServers, …)` runs in
  `McpClientManager.StartAsync` (a hosted service). DI registration stays side-effect-free and a
  bad config still fails startup (a hosted-service start failure stops the host).
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
- **Multipart uploads need Kestrel's limit raised and antiforgery disabled.** `Program.cs` sets
  `MaxRequestBodySize = maxFileSizeBytes + 1 MiB` (otherwise Kestrel rejects the request before
  the handler can return a friendly `413`), and `MapPost` opts out of antiforgery (the API is
  bearer-token, cookie-less). `WithExposedHeaders("Content-Disposition")` on the CORS policy lets
  a browser client read the download filename.
- **The Postgres attachment store's blob row FKs the metadata row.** Add `db.Attachments.Add(...)`
  *before* `store.PutAsync(...)` so `SaveChangesAsync` inserts metadata and blob in the right
  order; that is why `PutAsync` takes the `Attachment` rather than a bare stream.
- **The attachment capability gate is enforced server-side, not just in the client.** Never trust
  the client to have filtered unsupported files: `AttachmentGate` re-checks every referenced id
  against the resolved model's effective capabilities and `400`s a mismatch (video and unknown
  types are exempt — they are never sent to any model).
