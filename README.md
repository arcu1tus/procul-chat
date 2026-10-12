<div align="center">

<img src="assets/procul-logo.svg" alt="Procul" width="140" />

# Procul

**A streaming, tool-using chat app — an ASP.NET Core backend and a Flutter client.**

</div>

---

## ⚠️ This project was vibe-coded

Let's get this out of the way: **this repository was built by "vibe coding" with AI agents.**
The human involved wrote little to none of the code by hand. Strictly speaking, it isn't
their work — it's the output of an AI pair (or, more accurately, an AI driver) that was
steered, reviewed, and iterated on.

This started as an experiment: **how good is vibe coding, really, in 2026?** The honest
answer so far is **very, very impressive**. The app runs, streams, calls tools, renders
Markdown, persists conversations, has tests, and ships as a container — all from
natural-language direction. Treat the code accordingly: it is a demonstration, not a
hardened product. There is no warranty, no support, and no promise that any of it is the
*right* way to do things.

If you're here to judge the code, judge it as a snapshot of what AI-assisted development
looks like today. If you're here to use it, enjoy — but read the code first.

---

## What is Procul?

Procul is a small ChatGPT-style chat application:

- A **.NET 10 / ASP.NET Core minimal-API backend** that stores conversations in PostgreSQL,
  streams assistant replies over **Server-Sent Events (SSE)**, and lets the model call
  **tools** (current time, a sandboxed Python interpreter, and — when enabled — image generation
  and image display).
- A **Flutter client** (Linux desktop, web, and mobile) with multiple conversations
  (list / switch / rename / delete), streaming replies, tool-activity display, Markdown
  rendering, a persisted light/dark theme, a **token-usage dashboard**, and **multiple saved
  server profiles** behind a shared-password sign-in.

The model is reached through [`Microsoft.Extensions.AI`](https://learn.microsoft.com/dotnet/ai/microsoft-extensions-ai)
against [OpenRouter](https://openrouter.ai/).

## Features

- **Streaming replies** over SSE, with a `type`-tagged event protocol (`created`,
  `acknowledge`, `token`, `toolCall`, `toolResult`, `usage`, `image`, `title`, `error`, `done`).
- **Multiple models** declared in `config.jsonc`, each with its own client, capability metadata,
  and live health (`GET /v1/models`); a conversation remembers and can switch its model. The
  client picks the model per conversation from the chat app bar and lists every model — with
  capability badges and on-demand health checks — on a **Models** screen.
- **Token-usage tracking**: every model call (reply and title) records its input / output /
  cached / total tokens in PostgreSQL, and each assistant message is linked to its own usage row
  so the client can show **per-response** model + token details. The backend serves lifetime,
  per-day, and per-model totals from the authenticated `GET /v1/usage` endpoint (and
  per-conversation totals from `GET /v1/usage/conversations/{id}`); the client shows a live
  counter in the chat app bar and a **Usage** dashboard (daily chart, lifetime cards, per-model
  breakdown).
- **Agent tools** the model can call mid-turn: `get_current_time` and `run_python`
  (a contained, file/network-denying Python subset via `Lokad.Lython`), plus `show_image` and —
  when `imageGeneration.enabled` — `generate_image` (OpenRouter Image API or any OpenAI-compatible
  images endpoint). Generated/shown images are stored like uploads and streamed to the client as
  `image` events.
- **Media retention**: user uploads and generated images expire after a configurable window
  (default 14 days). Orphaned media is deleted outright; media attached to a message keeps its
  metadata but loses its bytes (an "expired" chip). Set `"0"` to keep media forever.
- **MCP tool servers**: connect to remote Streamable HTTP / SSE MCP servers, discover their
  tools, and expose them to the model (namespaced `{server}__{tool}`), with live status in the
  client's Settings.
- **File attachments**: attach images, text, PDFs, and (where the model supports it) audio to a
  message. Bytes land in PostgreSQL or S3-compatible storage (config choice); the backend maps
  each file to the content the selected model can read and **refuses** types it cannot — at
  upload *and* at send. The Flutter client picks from the native **Camera**, photo **Gallery**,
  or **Files** (Camera only where the OS provides one), multi-selects, restricts the picker to
  the active model's readable types, has removable preview chips, and renders images and files
  inline; reloaded conversations show their attachments (and, by default, re-sends them to the
  model on later turns).
- **AI-generated conversation titles** produced concurrently with the first reply.
- **Message editing** (destructive in v1): rewrite an earlier user message, optionally swap its
  attachments, and re-prompt the model. Every later message — and its attachments — is discarded,
  and the model replies afresh. A future version could branch instead (keep both versions).
- **Multi-device consistency**: each conversation carries a revision number, and mutating requests
  may echo the `expectedRevision` they last saw — a stale one is a `409 Conflict` instead of
  silently overwriting another device's change.
- **Multi-conversation UI** with rename, delete, and keyset-paginated history — **infinite scroll
  up** loads older messages, a **bottom pull-to-refresh** re-syncs without scrolling to the top,
  and a jump-to-latest pill returns to the newest message.
- **Responsive shadcn UI** with dark mode by default, hand-rolled skeletons, and subtle
  motion (including a shimmer sweep over assistant text while it streams).
- **Password-protected API** with expiring HS256 session tokens stored in the device's secure
  storage, plus a public `/health` probe.
- **Multiple server profiles** the client can add, switch between, and remove.
- **Versioned API** (`/v1/conversations`) built for additive evolution.
- **Containerized backend** published to GitHub Container Registry on version tags.

## Repository layout

```
.
├── docs/                    # operator guides: docker-compose, flutter-builds, configuration
├── justfile                 # root task runner (just modules: `just backend …`, `just frontend …`)
├── backend/                 # ASP.NET Core (.NET 10) API
│   ├── src/Procul.Api/       # the API project
│   │   ├── Chat/             # endpoints, streaming service, model registry/catalog, tools, DTOs, entities
│   │   ├── Attachments/      # upload/download/delete + the Postgres/S3 store + capability gate
│   │   ├── Configuration/    # config.jsonc loader (JSONC + schema + ${ENV}) + derived options
│   │   ├── Usage/            # token-usage aggregation + `GET /v1/usage` endpoints
│   │   ├── Cors/             # browser CORS policy
│   │   ├── Security/         # shared-password auth: verifier, session JWTs, endpoints
│   │   ├── Infrastructure/   # EF Core DbContext
│   │   ├── Migrations/       # EF Core migrations
│   │   ├── Versioning/       # API versioning
│   │   └── Dockerfile        # multi-stage, cache-friendly image
│   ├── tests/Procul.Api.Tests/  # xUnit unit + integration tests
│   ├── justfile              # build/test/run + dev Postgres + container helpers
│   ├── Procul.slnx           # solution
│   └── AGENTS.md             # backend conventions & gotchas
├── frontend/                # Flutter client
│   ├── lib/                  # app + src (API client, controllers, UI)
│   ├── test/                 # unit + widget tests
│   ├── justfile              # dev/test + per-platform release builds
│   └── AGENTS.md             # frontend conventions & gotchas
├── assets/                  # logo
└── .github/workflows/       # CI + container publishing
```

Each of `backend/` and `frontend/` has its own **`AGENTS.md`** with the detailed
architecture, conventions, and hard-won gotchas. Those are the best place to start reading.

## Tech stack

| Layer    | Technology |
| -------- | ---------- |
| Backend  | .NET 10, ASP.NET Core minimal APIs, EF Core 10 + Npgsql, `Microsoft.Extensions.AI`, `Asp.Versioning`, `Lokad.Lython` |
| Database | PostgreSQL |
| Frontend | Flutter (Dart 3), `shadcn_flutter`, `gpt_markdown`, `google_fonts`, `fl_chart`, `package:http`, `flutter_secure_storage` |
| Model    | OpenRouter (any model slug you configure) |
| CI/CD    | GitHub Actions, Docker Buildx, GitHub Container Registry |

## Getting started

### Prerequisites

- [.NET 10 SDK](https://dotnet.microsoft.com/download)
- [Docker](https://www.docker.com/) (for the dev Postgres, and for building the image)
- [Flutter](https://flutter.dev/) (for the client)
- [just](https://github.com/casey/just) (≥ 1.0 — optional but recommended; the repo's
  `justfile`s wrap every common task)
- An [OpenRouter](https://openrouter.ai/) API key

### Backend

```bash
cd backend
dotnet build Procul.slnx            # build the solution
dotnet test  Procul.slnx            # run the tests (no database or network needed)
```

Create the environment file (it is git-ignored — **never commit it**):

```bash
cp backend/src/Procul.Api/.env.example backend/src/Procul.Api/.env
# then edit .env and fill in your values
```

Run it (starts Postgres via Docker Compose, then the API):

```bash
cd backend
just run                            # dev Postgres + `dotnet run`; or: `just backend run` from the root
```

The API listens on **http://localhost:5010**. Migrations are applied automatically at
startup — the app creates the database if needed and applies any pending migrations.

### Frontend

```bash
cd frontend
flutter pub get
flutter run -d linux                # native Linux desktop
flutter run -d chrome               # web
```

The base URL defaults to `http://localhost:5010` and can be overridden at build time:

```bash
flutter run -d linux --dart-define=PROCUL_API_BASE=http://localhost:5010
```

On first launch the app shows a **Connect** screen: enter the server URL (pre-filled from
`PROCUL_API_BASE`) and the backend's `PROCUL_API_PASSWORD`. The session token is stored in the
device's secure storage, and Settings lets you add, switch between, and remove **multiple
server profiles** or log out. The chat app bar carries a **model picker** for the active
conversation (hidden when only one model is configured), and the sidebar's **Models** entry
opens a catalog of every configured model with its capabilities and live health.

## Configuration

The backend reads its configuration from a single **`config.jsonc`** file (JSONC: comments and
trailing commas are allowed). `.env` holds **secrets only**; `config.jsonc` references them as
`${VAR}`. The loader resolves every reference from the process environment at startup, and an
unresolved reference names the missing variable and aborts startup.

> **Full reference:** [`docs/configuration.md`](docs/configuration.md) documents every section,
> field, default, and validation rule.

Copy the example and edit it:

```bash
cp backend/src/Procul.Api/config.jsonc.example backend/src/Procul.Api/config.jsonc
```

| Section | Purpose |
| ------- | ------- |
| `server.corsAllowedOrigins[]` | Browser origins allowed to call the API |
| `server.sessionLifetime` | Session-token lifetime, e.g. `12h` (default `30d`) |
| `database.connectionString` | PostgreSQL connection string |
| `attachments.*` | Upload storage (`postgres`/`s3`), size limit, allowed content types, history re-send, text-inline cap, **retention** (default `14d`) |
| `imageGeneration.*` | The `generate_image` tool (provider, model, key, defaults, **retention**) — disabled by default |
| `models[]` | One or more chat models (slug, name, base URL, key, provider, capabilities, default) |
| `titleModel` | Optional slug used for the AI title call (defaults to the conversation's model) |
| `modelHealth.*` | Liveness-probe enable/interval/timeout/prompt |
| `mcp` + `mcpServers` | MCP client settings and remote tool servers |

Two environment variables remain outside `config.jsonc`:

| Variable | Purpose |
| -------- | ------- |
| `PROCUL_API_PASSWORD` | Shared password protecting the API (**required**) |
| `PROCUL_CONFIG_PATH` | Path to `config.jsonc` (default: `config.jsonc` next to the app) |

Secrets referenced from `config.jsonc` as `${VAR}` live in `.env` (git-ignored):
`OPENROUTER_KEY`, `DB_CONNECTION_STRING`, optional `S3_*`, `GITHUB_MCP_TOKEN`, and
`PROCUL_API_PASSWORD`. `.env.example` documents the shape. **No secrets are committed**, and the
container image is environment-agnostic — configuration is injected at run time.

### Multiple models

`models[]` declares every model the backend can use. Each gets its own `IChatClient`, and the
client can list them (with capabilities and live health) via the authenticated
`GET /v1/models` endpoint (never returning API keys). A conversation remembers the model it was
created with; the model can be changed with `PUT /v1/conversations/{id}/model`, and a stale slug
falls back to the default.

```jsonc
"models": [
  {
    "slug": "openrouter/free",        // also the id sent on the wire
    "name": "Free models",
    "apiKey": "${OPENROUTER_KEY}",
    "baseUrl": "https://openrouter.ai/api/v1",
    "provider": "openrouter",         // optional; inferred from baseUrl otherwise
    "capabilities": ["text", "image"],// optional; discovered from OpenRouter when omitted
    "default": true,
    "healthCheck": true
  }
]
```

On startup each model is probed once (unless `healthCheck: false`), and capabilities are
discovered from OpenRouter's `/models` when possible. Every 30 minutes a model that had **no
real traffic** in the window is probed again; models just used by live traffic are left alone.

### Attachments

Files attached to a message are validated, stored, and translated into the content the selected
model can read. Metadata always lives in PostgreSQL; the **bytes** go to
`attachments.storage`: `postgres` (a `bytea` table, the default) or `s3` (any S3-compatible
service, including MinIO via `serviceUrl` + `forcePathStyle`).

```jsonc
"attachments": {
  "storage": "postgres",            // "postgres" | "s3"
  "maxFileSizeBytes": 20971520,     // 20 MiB (the client pre-checks the same limit)
  "allowedContentTypes": ["image/*", "text/*", "application/pdf", "audio/mpeg", "audio/wav"],
  "resendHistory": true,            // true = earlier turns re-send the bytes, so a model
                                    // picked later can still read them; false = note only
  "textInlineMaxBytes": 262144,     // cap for inlining a text/* file into the prompt
  "retention": "14d",               // media age limit; "0" = keep forever
  "s3": { "bucket": "${S3_BUCKET}", "region": "${S3_REGION}", "serviceUrl": "${S3_ENDPOINT}",
          "forcePathStyle": true, "accessKey": "${S3_ACCESS_KEY}", "secretKey": "${S3_SECRET_KEY}" }
}
```

On send, each attachment is mapped to `Microsoft.Extensions.AI` content:

| Type | Sent as | Requires |
| ---- | ------- | -------- |
| `image/*` | image part | `image` capability |
| `application/pdf` | file part | `file`/`pdf` capability |
| `audio/mpeg`, `audio/wav` | input-audio part | `audio` capability |
| `text/*` | inlined `TextContent` (capped) | — (always) |
| video / anything else | not sent; a text placeholder | — (stored + shown only) |

The model's effective capabilities (declared ∪ discovered) are enforced by the backend: a file
whose type the selected model cannot read is rejected with a `400` naming the file and the
missing capability — both at **upload** (the client sends the target model as `?model=...`) and
again at **send** (the model can change in between). The client also restricts the native picker
to that model's readable types, so an unsupported file usually cannot even be chosen; video is
never offered, because no configured model can receive it.

With `resendHistory: true` (the default), every turn re-sends the bytes of earlier user messages
that have attachments, so switching to a more capable model later lets it read files attached
before the switch. A per-attachment capability check still degrades any type the current model
cannot read to a placeholder. Set it to `false` to send the bytes only on the turn the file was
attached and use a short text note for earlier turns.

### Image generation & media retention

The model can **generate** images (when `imageGeneration.enabled` is true) and **show** images from
a URL or base64 bytes via the `show_image` tool. Generated/shown images are stored like uploads
(PostgreSQL or S3) and served from `GET /v1/attachments/{id}`, so the client shows them inline and
they survive a reload:

```jsonc
"imageGeneration": {
  "enabled": false,                  // off by default; enables generate_image
  "provider": "openrouter",          // "openrouter" (POST {baseUrl}/images) | "openai-compatible"
  "baseUrl": "https://openrouter.ai/api/v1",
  "apiKey": "${OPENROUTER_KEY}",
  "model": "google/gemini-2.5-flash-image",
  "defaultSize": "1024x1024",
  "defaultAspectRatio": "1:1",
  "maxReferenceImages": 4,
  "timeout": "120s",
  "retention": "14d"                 // omit to inherit attachments.retention
}
```

Media expires after a configurable window (`attachments.retention` for uploads,
`imageGeneration.retention` for generated/shown images; both default **14 days**). Orphaned media
(uploaded but never sent, a failed send, or an image from a turn that never persisted) is deleted
outright; media attached to a message keeps its metadata but loses its bytes, so history shows an
"expired" chip. Set a window to `"0"` to keep media forever.

### MCP tool servers

The model can call tools from remote [MCP](https://modelcontextprotocol.io/) servers
(Streamable HTTP and legacy SSE) in addition to the built-in ones. Servers live under
`mcpServers` in the same `config.jsonc`:

```jsonc
"mcpServers": {
  "github": {
    "type": "http",                                  // "http" | "sse"
    "url": "https://api.githubcopilot.com/mcp/",
    "headers": { "Authorization": "Bearer ${GITHUB_MCP_TOKEN}" },
    "enabled": true                                  // optional, default true
  }
}
```

On startup the backend connects to every enabled server, discovers its tools, and logs a
per-server status; a server that is down is retried in the background and never blocks startup.
Tools are namespaced `{server}__{tool}`. The authenticated `GET /v1/mcp/servers` endpoint reports
live status (never headers or tokens), and the client shows it read-only in Settings.

### CORS in production

Native desktop and mobile clients are not subject to CORS, but a **Flutter web build is**.
The rules are:

- **Development:** if `server.corsAllowedOrigins` is empty, any origin is allowed (the web dev
  server's port is ephemeral). This never applies outside development.
- **Production (and any other environment):** there is **no wildcard**. Cross-origin
  requests are denied until you set `server.corsAllowedOrigins` to the frontend's real origin,
  e.g. `"corsAllowedOrigins": ["https://app.example.com"]`. A wildcard (`*`) or a malformed
  origin makes startup fail fast.

Build the production web client against your API's public URL:

```bash
flutter build web --release --dart-define=PROCUL_API_BASE=https://api.example.com
```

## Testing

```bash
# Everything at once (from the repo root): backend tests + frontend tests + analyzer
just check

# Or individually:
# Backend: unit + integration tests (xUnit), no database or network required
dotnet test backend/Procul.slnx

# Frontend: unit + widget tests
cd frontend && flutter test
cd frontend && flutter analyze     # must stay clean
```

The backend suite covers title generation and sanitization, tool invocation (time, the
Python sandbox's isolation guarantees, image generation, and show-image), media retention,
token-usage aggregation and its HTTP pipeline, per-response metadata, optimistic concurrency
(409), the SSE/JSON wire contract, API versioning, and the CORS policy — including a full
`WebApplicationFactory` preflight test against the real pipeline — plus the attachment stores,
validation, the content-mapping table, and an end-to-end upload → download → attach →
model-request test.

## Container image

The backend ships as a multi-stage image (`backend/src/Procul.Api/Dockerfile`): a .NET 10
SDK stage restores and publishes, and a slim ASP.NET Core runtime stage runs the app as a
non-root user on port `8080`. The NuGet restore layer is cached independently of the source
(and via a BuildKit cache mount), so repeat builds are fast.

The container manages its own schema: on startup it applies pending EF Core migrations
(creating the database if needed), so no separate `dotnet ef` step is required. It only
needs the connection string above to point at a reachable PostgreSQL.

> **Running from the published image?** [`docs/docker-compose.md`](docs/docker-compose.md) has a
> complete `compose.yaml` (Postgres + the `ghcr.io` image), secrets, MinIO/S3, reverse-proxy/TLS
> with CORS, upgrades, and troubleshooting.

Build and run it locally:

```bash
docker build -f backend/src/Procul.Api/Dockerfile -t procul-api backend

docker run --rm -p 8080:8080 \
  -e PROCUL_API_PASSWORD=a-strong-shared-password \
  -e OPENROUTER_KEY=sk-or-v1-... \
  -e DB_CONNECTION_STRING="Host=...;Port=5432;Database=procul;Username=...;Password=..." \
  -e GITHUB_MCP_TOKEN=ghp_... \
  -v ./config.jsonc:/app/config.jsonc:ro \
  procul-api
```

The `-v` mount injects `config.jsonc` read-only; the secrets it references as `${VAR}` come from
`-e` (or the environment), so the mounted file stays secret-free. The runtime image is
ASP.NET-only, which is fine: remote MCP transports spawn no child processes.

### Publishing

Publishing is **tag-driven**. Push a `v*` tag and the
[`publish-backend-image`](.github/workflows/publish-backend-image.yml) workflow tests the
solution and pushes the image to GitHub Container Registry:

```
ghcr.io/<owner>/<repo>/backend-api:<version>
ghcr.io/<owner>/<repo>/backend-api:<major>.<minor>
ghcr.io/<owner>/<repo>/backend-api:<major>
ghcr.io/<owner>/<repo>/backend-api:sha-<commit>
ghcr.io/<owner>/<repo>/backend-api:latest      # stable tags only
```

It authenticates with the built-in `GITHUB_TOKEN` (`packages: write`) — no extra secrets —
and reuses the Docker layer cache through the Actions cache API.

## Continuous integration

- [`ci.yml`](.github/workflows/ci.yml) builds and tests the backend on pushes to `main` and
  on pull requests.
- [`publish-backend-image.yml`](.github/workflows/publish-backend-image.yml) tests and
  publishes the container image on `v*` tags.

## License & disclaimer

No license is currently declared. The code is provided **as-is**, with no warranty of any
kind. It is a vibe-coding experiment — **use it, fork it, learn from it, but don't trust it
in production without reviewing it yourself.** See the note at the top of this README.
