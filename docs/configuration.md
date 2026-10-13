# Configuration reference

The backend is configured by a single **`config.jsonc`** file. It is the **source of truth** for
everything except a handful of secrets and the file's own location. It is read **exactly once at
startup**, before any dependency-injection wiring; a missing, malformed, or invalid file **aborts
startup**.

- **JSONC** is accepted: `//` and `/* */` comments and trailing commas are allowed.
- Start from the committed example:
  [`backend/src/Procul.Api/config.jsonc.example`](../backend/src/Procul.Api/config.jsonc.example).
- [`config.schema.json`](../backend/src/Procul.Api/config.schema.json) is the machine-readable
  schema (JSON Schema 2020-12). The example sets `"$schema": "./config.schema.json"` so editors
  offer completion and inline validation.

## How the file is loaded

`Program.cs` calls `Configuration/ProculConfigLoader.Load` before building the host. The pipeline
is:

1. **Locate** — the path from `PROCUL_CONFIG_PATH`, else `config.jsonc` next to the app.
2. **Parse** — JSONC (comments + trailing commas).
3. **Validate against the schema** — `config.schema.json` next to the app (copied to the output
   directory at build time).
4. **Deserialize** into the `ProculConfig` POCOs.
5. **Expand `${VAR}` references** in every string value from the process environment (see
   [Secrets](#secrets-and-var)).
6. **Domain-validate, fail fast** — at least one model; exactly one `default` (at most); unique
   slugs; absolute `http(s)` `baseUrl`; known `provider`/`capabilities`; `attachments.storage` in
   `{postgres, s3}`; valid durations; `titleModel` references a configured slug.

Any failure prints a precise message naming the file and the offending value, and the process
exits. You never get a half-configured server.

## Sections

| Section | Required | Purpose |
| ------- | -------- | ------- |
| [`server`](#server) | no | CORS origins and session-token lifetime |
| [`database`](#database) | no\* | PostgreSQL connection string |
| [`attachments`](#attachments) | no | Upload storage, limits, retention, and content mapping |
| [`imageGeneration`](#imagegeneration) | no | The `generate_image` tool and generated-image retention |
| [`models`](#models) | **yes** | One or more chat models |
| [`titleModel`](#titlemodel) | no | Slug for the AI title call |
| [`modelHealth`](#modelhealth) | no | Model liveness probing |
| [`mcp`](#mcp) | no | MCP client settings (master switch + timeouts) |
| [`mcpServers`](#mcpservers) | no | Remote MCP tool servers |

\* Omitting `database` leaves the database unconfigured — useful for tests, but a real deployment
needs it: the API requires PostgreSQL to store conversations, messages, attachments, and usage.

---

### `server`

| Field | Type | Default | Meaning |
| ----- | ---- | ------- | ------- |
| `corsAllowedOrigins` | `string[]` | `[]` | Browser origins allowed to call the API. **Development:** an empty list allows *any* origin (the Flutter web dev server uses an ephemeral port). **Everywhere else:** only the listed origins are allowed — there is **no wildcard**. A `*` or a malformed value (not an absolute `http(s)` origin, or one carrying a path) fails startup. Entries are trimmed and normalized (trailing slash removed). |
| `sessionLifetime` | duration | `30d` | Lifetime of an issued session token (see [Authentication](../backend/AGENTS.md#authentication)). Changing `PROCUL_API_PASSWORD` invalidates every token regardless. |

```jsonc
"server": {
  "corsAllowedOrigins": ["https://app.example.com"],
  "sessionLifetime": "12h"
}
```

> **A Flutter web build is a browser client and is subject to CORS.** List its exact origin here,
> e.g. `"https://app.example.com"`. Native desktop/mobile clients are not affected. See
> [`flutter-builds.md`](flutter-builds.md#web).

### `database`

| Field | Type | Default | Meaning |
| ----- | ---- | ------- | ------- |
| `connectionString` | string (`${VAR}` ok) | _unset_ | Npgsql/PostgreSQL connection string. When unset the app runs **without a database** (the integration tests rely on this) and skips migrations. |

```jsonc
"database": { "connectionString": "${DB_CONNECTION_STRING}" }
```

On startup the app **applies pending EF Core migrations automatically** (creating the database if
needed) whenever a connection string is configured. There is no separate migration step.

### `attachments`

| Field | Type | Default | Meaning |
| ----- | ---- | ------- | ------- |
| `storage` | `"postgres"` \| `"s3"` | `postgres` | Where the file **bytes** live. Metadata always lives in PostgreSQL. |
| `maxFileSizeBytes` | integer ≥ 1 | `20971520` (20 MiB) | Largest accepted upload. Kestrel's body limit is raised to this plus 1 MiB so the handler (not Kestrel) returns a friendly `413`. The Flutter client pre-checks the same limit. |
| `allowedContentTypes` | `string[]` | `[]` | Content-type **patterns** (wildcards like `image/*` allowed). An **empty list rejects every upload**, so set it explicitly. |
| `resendHistory` | boolean | `true` | `true` re-sends earlier turns' attachment bytes every turn (so a model chosen later can still read them); `false` sends the bytes only on the turn the file was attached and a short text note afterwards. |
| `textInlineMaxBytes` | integer ≥ 1 | `262144` (256 KiB) | Cap on how much of a `text/*` file is inlined into the prompt. |
| `retention` | duration \| `"0"` | `14d` | Media age limit. After the window, **orphaned** media (never attached to a message) is deleted outright and **referenced** media keeps its metadata but loses its bytes (history shows an "expired" chip; `GET /v1/attachments/{id}` 404s). `"0"` keeps media forever. See [Retention](#retention). |
| `s3` | object | – | Required when `storage` is `s3`. See below. |

`attachments.s3`:

| Field | Type | Meaning |
| ----- | ---- | ------- |
| `bucket` | string | Bucket name. |
| `region` | string | AWS region (e.g. `us-east-1`). |
| `serviceUrl` | string | Custom endpoint for MinIO / S3-compatible services. **Omit for AWS.** |
| `forcePathStyle` | boolean | Use path-style addressing (required by MinIO). |
| `accessKey` | string (`${VAR}` ok) | Access key; omit to use the default AWS credential chain. |
| `secretKey` | string (`${VAR}` ok) | Secret key. |

```jsonc
"attachments": {
  "storage": "postgres",
  "maxFileSizeBytes": 20971520,
  "allowedContentTypes": ["image/*", "text/*", "application/pdf", "audio/mpeg", "audio/wav"],
  "resendHistory": true,
  "textInlineMaxBytes": 262144,
  "retention": "14d",
  "s3": {
    "bucket": "${S3_BUCKET}",
    "region": "${S3_REGION}",
    "serviceUrl": "${S3_ENDPOINT}",   // set for MinIO; omit for AWS
    "forcePathStyle": true,
    "accessKey": "${S3_ACCESS_KEY}",
    "secretKey": "${S3_SECRET_KEY}"
  }
}
```

How each attachment type is mapped to model content — and which **capability** it requires — is
documented in [`../backend/AGENTS.md`](../backend/AGENTS.md#attachments) and mirrored in the
top-level README. In short: `image/*` → image part (`image`), `application/pdf` → file part
(`file`/`pdf`), `audio/*` → input-audio (`audio`), `text/*` always inlined, everything else
(video, unknown) stored and shown but never sent. The backend enforces the capability gate at
**upload** *and* at **send**.

#### Retention

Media lives forever only if you set `"0"`. Otherwise the backend applies an **age limit** (default
**14 days**) per category — `attachments.retention` for uploads and `imageGeneration.retention`
for generated/shown images — via a background sweep (hourly). Two outcomes, driven by the same
window:

1. **Orphaned media** (`messageId` is null — uploaded but never sent, a failed send, or a generated
   image from a turn that never persisted) is **deleted outright** (metadata + bytes).
2. **Referenced media** (attached to a message) keeps its **metadata** but loses its **bytes**, so
   history still shows an "expired" chip and `GET /v1/attachments/{id}` returns `404`.

Bytes are always deleted through the configured store (S3 objects do not cascade with the database
rows). Set the window to `"0"` to keep media indefinitely.

### `models`

A non-empty array; each entry is one usable chat model. `config.jsonc` is the multi-model source
of truth (it replaced the old `OPENROUTER_MODEL_SLUG`/`OPENROUTER_API_KEY` pair).

| Field | Type | Required | Default | Meaning |
| ----- | ---- | -------- | ------- | ------- |
| `slug` | string | **yes** | – | The model id sent on the wire and the registry key. Must be unique. May contain `/` (e.g. `openrouter/anthropic/claude-3.5`). |
| `name` | string | no | slug | Human-readable name shown in the client. |
| `description` | string | no | – | Shown in the client's Models screen. |
| `apiKey` | string (`${VAR}` ok) | no | – | Provider API key. **Never returned by the API.** |
| `baseUrl` | string | **yes** | – | Provider base URL; must be an absolute `http(s)` URL, e.g. `https://openrouter.ai/api/v1`. |
| `provider` | `"openrouter"` \| `"openai-compatible"` | no | inferred | Inferred from `baseUrl` when omitted (`openrouter.ai` → OpenRouter). |
| `capabilities` | array of `text`\|`image`\|`audio`\|`video`\|`pdf` | no | discovered | Declared input modalities. When omitted (or `discoverCapabilities` is on) they are discovered from the provider. |
| `default` | boolean | no | `false` | Marks the default model. At most one model may set this; if none does, the first configured model is used (with a warning). |
| `healthCheck` | boolean | no | `true` | Whether this model is probed at startup and on the idle cadence. |
| `discoverCapabilities` | boolean | no | `true` | Whether to query the provider's `/models` endpoint for capabilities. |
| `maxOutputTokens` | integer ≥ 1 | no | – | Upper bound on output tokens for each reply/tool-loop model call, or the provider default. Titles and health probes use their own caps. |

```jsonc
"models": [
  {
    "slug": "openrouter/free",
    "name": "Free models",
    "description": "Free models from OpenRouter",
    "apiKey": "${OPENROUTER_KEY}",
    "baseUrl": "https://openrouter.ai/api/v1",
    "provider": "openrouter",
    "capabilities": ["text", "image"],
    "default": true,
    "healthCheck": true,
    "discoverCapabilities": true,
    "maxOutputTokens": 4096
  }
]
```

**Capabilities are `declared ∪ discovered`.** The effective set is the union of whatever you list
and whatever the provider reports; `text` is the fallback when nothing is known. The client shows
these as badges, and the backend uses them for the attachment gate.

**Per-conversation selection.** A conversation remembers the model it was created with
(`POST /v1/conversations` accepts an optional `model`), which can be changed later with
`PUT /v1/conversations/{id}/model`. A slug that no longer exists falls back to the default with a
warning. `GET /v1/models` lists every model with capabilities and live health, **never** a key.

### `titleModel`

Optional. The slug used for the small, concurrent title-generation call. Defaults to the
conversation's model. Must reference a configured slug.

```jsonc
"titleModel": "openrouter/free"
```

### `imageGeneration`

Controls the `generate_image` tool (and the `show_image` tool's stored media). **Disabled by
default**: with `enabled: false` the tool is not offered to the model and the system prompt does
not mention it.

| Field | Type | Default | Meaning |
| ----- | ---- | ------- | ------- |
| `enabled` | boolean | `false` | Master switch for `generate_image`. |
| `provider` | `"openrouter"` \| `"openai-compatible"` | `openrouter` | `openrouter` uses the dedicated Image API (`POST {baseUrl}/images`); `openai-compatible` uses `POST {baseUrl}/images/generations`. |
| `baseUrl` | string | `https://openrouter.ai/api/v1` | Provider base URL (absolute `http(s)`). |
| `apiKey` | string (`${VAR}` ok) | – | Provider key. **Never returned by the API.** Reuses `OPENROUTER_KEY` in the example. |
| `model` | string | `google/gemini-2.5-flash-image` | An image-**output** model. Required when `enabled` is true. |
| `defaultSize` | string | `1024x1024` | Default size when the model omits one. |
| `defaultAspectRatio` | string | `1:1` | Default aspect ratio when the model omits one. |
| `maxReferenceImages` | integer ≥ 0 | `4` | Cap on reference images sent with one generation. |
| `timeout` | duration | `120s` | Per-request budget. |
| `retention` | duration \| `"0"` | inherits `attachments.retention` | Age limit for generated/shown images; same semantics as `attachments.retention`. |

```jsonc
"imageGeneration": {
  "enabled": false,
  "provider": "openrouter",
  "baseUrl": "https://openrouter.ai/api/v1",
  "apiKey": "${OPENROUTER_KEY}",
  "model": "google/gemini-2.5-flash-image",
  "defaultSize": "1024x1024",
  "defaultAspectRatio": "1:1",
  "maxReferenceImages": 4,
  "timeout": "120s",
  "retention": "14d"
}
```

Generated and shown images are stored like uploads and served from `GET /v1/attachments/{id}`; the
chat receives an `image` SSE event carrying the attachment id. The `show_image` tool (URL or
base64) is always offered; its URL fetches are SSRF-guarded (public `http(s)` only). Every
redirect destination is checked, with at most five redirects per fetch. DNS rebinding is still
a limitation because the HTTP connection resolves the hostname again.

### `modelHealth`

Controls the catalog/health service (`Chat/Models/ModelCatalogService`).

| Field | Type | Default | Meaning |
| ----- | ---- | ------- | ------- |
| `enabled` | boolean | `true` | Master switch for the whole service. `false` disables probing and capability discovery. |
| `interval` | duration | `30m` | Idle re-probe cadence. On each tick, **only** models with no real traffic in the window are re-probed — models just used by live traffic are left alone. |
| `timeout` | duration | `10s` | Per-probe budget. |
| `probePrompt` | string | `"Reply with the single word: alive"` | The prompt sent to confirm a model is alive. |
| `maxOutputTokens` | integer ≥ 1 | `5` | Output-token cap for a probe. |

At startup each health-checked model is discovered and probed once. Failures are never fatal. The
authenticated `GET /v1/models` reports status; `POST /v1/models/check` and
`POST /v1/models/{slug}/check` trigger on-demand probes.

```jsonc
"modelHealth": {
  "enabled": true,
  "interval": "30m",
  "timeout": "10s",
  "probePrompt": "Reply with the single word: alive",
  "maxOutputTokens": 5
}
```

### `mcp`

Master switch and timings for the MCP client (remote tool servers).

| Field | Type | Default | Meaning |
| ----- | ---- | ------- | ------- |
| `enabled` | boolean | `true` | When `false`, configured servers are never connected. |
| `connectTimeout` | duration | `15s` | Per-server connect + tool-discovery budget. |
| `healthInterval` | duration | `60s` | Background ping/reconnect cadence. |

```jsonc
"mcp": { "enabled": true, "connectTimeout": "15s", "healthInterval": "60s" }
```

### `mcpServers`

A map of **name → server**. Only remote transports are supported (`http` = Streamable HTTP,
`sse` = legacy); there is no stdio transports because the runtime image is ASP.NET-only.

| Field | Type | Required | Default | Meaning |
| ----- | ---- | -------- | ------- | ------- |
| `type` | `"http"` \| `"sse"` (aliases `streamable-http`, `streamablehttp`) | **yes** | – | Transport. |
| `url` | string | **yes** | – | Absolute `http(s)` URL of the MCP endpoint. |
| `headers` | object of string | no | – | Extra headers (e.g. an `Authorization` bearer). Reference secrets as `${VAR}`. **Never logged or returned.** |
| `enabled` | boolean | no | `true` | Skip a server without deleting it. |

```jsonc
"mcpServers": {
  "github": {
    "type": "http",
    "url": "https://api.githubcopilot.com/mcp/",
    "headers": { "Authorization": "Bearer ${GITHUB_MCP_TOKEN}" },
    "enabled": true
  }
}
```

On startup the backend connects to every enabled server, discovers its tools, and logs a per-server
status. Tools are namespaced `{server}__{tool}` and join the built-in tools each turn. An
**unreachable server is not fatal** (it is retried in the background); a **misconfigured** server
(unknown type, missing/invalid URL, blank name) **is** fatal. The authenticated
`GET /v1/mcp/servers` reports live status without secrets.

---

## Secrets and `${VAR}`

`config.jsonc` never *contains* secrets — string values reference environment variables as
`${VAR}`, and the loader replaces them from the process environment at startup. **An unresolved
reference is fatal and names the missing variable**, so a forgotten secret is obvious immediately.

By convention the secrets live in a git-ignored **`.env`** file next to the backend
(`backend/src/Procul.Api/.env`), loaded by `DotNetEnv` before the config is read. Copy
[`.env.example`](../backend/src/Procul.Api/.env.example) to get started. **Never commit `.env`.**

The example references these variables:

| Variable | Referenced from | Purpose |
| -------- | --------------- | ------- |
| `DB_CONNECTION_STRING` | `database.connectionString` | PostgreSQL connection string |
| `OPENROUTER_KEY` | `models[].apiKey`, `imageGeneration.apiKey` | OpenRouter API key |
| `S3_BUCKET` / `S3_REGION` / `S3_ENDPOINT` / `S3_ACCESS_KEY` / `S3_SECRET_KEY` | `attachments.s3.*` | Only when `attachments.storage` is `s3` |
| `GITHUB_MCP_TOKEN` | `mcpServers.*.headers` | Example MCP server token |

## Environment variables that live outside the file

Two are read directly by the process (not from `config.jsonc`):

| Variable | Required | Default | Purpose |
| -------- | -------- | ------- | ------- |
| `PROCUL_CONFIG_PATH` | no | `config.jsonc` next to the app | Path to the config file (absolute or relative). |
| `PROCUL_API_PASSWORD` | **yes** | – | The shared password protecting the whole API. Startup **fails fast** when it is unset/empty. It is never stored in `config.jsonc`. |

> **Design-time note.** Because the config is loaded in `Program.cs`, EF Core design-time commands
> run it too. Set `PROCUL_CONFIG_PATH` (and `PROCUL_API_PASSWORD`) when running
> `dotnet ef migrations …`, e.g.
> `PROCUL_CONFIG_PATH=/tmp/config.jsonc PROCUL_API_PASSWORD=x dotnet ef migrations add Foo`.

## Durations

Every duration field (`sessionLifetime`, `modelHealth.interval`/`timeout`,
`mcp.connectTimeout`/`healthInterval`, `imageGeneration.timeout`, `attachments.retention`/
`imageGeneration.retention`) accepts one or more `<number><unit>` segments, where the unit is `d`,
`h`, `m`, or `s`: `30d`, `12h`, `90s`, `1h30m`. A malformed value fails startup and names the
field. A **retention** field additionally accepts the literal `"0"`, meaning "keep forever"
(retention disabled for that category).

## Related pages

- **[`docker-compose.md`](docker-compose.md)** — a ready-made compose file that mounts this
  `config.jsonc` and injects the secrets via `env_file`.
- **[`../backend/AGENTS.md`](../backend/AGENTS.md)** — the full backend architecture and gotchas.
