# Running the backend with Docker Compose

Run the published Procul backend image alongside PostgreSQL with Docker Compose — no .NET SDK
required. The image is **environment-agnostic**: it bakes in nothing but the app and its example
config, and reads everything at run time from a mounted `config.jsonc` plus environment variables.

> Prefer to run from source? See the top-level [`README.md`](../README.md) and
> [`../backend/AGENTS.md`](../backend/AGENTS.md). This page is only about the container.

## The published image

The backend is published to GitHub Container Registry by
[`.github/workflows/publish-backend-image.yml`](../.github/workflows/publish-backend-image.yml)
on every `v*` tag:

```
ghcr.io/<owner>/procul-chat/backend-api:<tag>
```

(Registry paths must be lowercase; the workflow lowercases the owner/repo.) For this repository
that is `ghcr.io/arcu1tus/procul-chat/backend-api`.

| Tag | Example | Notes |
| --- | ------- | ----- |
| Full version | `:1.2.3` | The exact `v1.2.3` tag. |
| Major.minor | `:1.2` | Floating within the minor line. |
| Major | `:1` | Floating within the major line. |
| Commit | `:sha-1a2b3c4` | A specific commit, for pinning. |
| `latest` | `:latest` | **Stable (non-prerelease) tags only.** |

The image is built for **`linux/amd64`** only. On an arm64 host, run it under emulation
(Docker Desktop does this automatically) or build it locally:

```bash
docker build -f backend/src/Procul.Api/Dockerfile -t procul-api backend
```

## Quick start

1. **Create a config** and **a secrets file** next to your `compose.yaml`:

   ```bash
   curl -O https://raw.githubusercontent.com/arcu1tus/procul-chat/main/backend/src/Procul.Api/config.jsonc.example
   mv config.jsonc.example config.jsonc
   ```

   ```bash
   # .env  — git-ignore this file
   POSTGRES_PASSWORD=change-me-to-something-long
   PROCUL_API_PASSWORD=change-me-too
   OPENROUTER_KEY=sk-or-v1-...
   ```

2. **Write `compose.yaml`** (below), then:

   ```bash
   docker compose up -d
   docker compose logs -f api        # watch startup + migrations
   ```

3. The API is on **http://localhost:8080**; `curl http://localhost:8080/health` returns
   `{"status":"healthy"}`. Point the Flutter client at it (see
   [`flutter-builds.md`](flutter-builds.md)).

## A complete `compose.yaml`

```yaml
name: procul

services:
  postgres:
    image: postgres:alpine
    restart: unless-stopped
    environment:
      POSTGRES_USER: procul
      POSTGRES_PASSWORD: ${POSTGRES_PASSWORD:?set POSTGRES_PASSWORD in .env}
      POSTGRES_DB: procul
    volumes:
      # Mount the parent dir: correct for both PG17 (/data subdir) and PG18+ layouts.
      - postgres_data:/var/lib/postgresql
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U procul -d procul"]
      interval: 10s
      timeout: 5s
      retries: 5

  api:
    image: ghcr.io/arcu1tus/procul-chat/backend-api:latest
    restart: unless-stopped
    depends_on:
      postgres:
        condition: service_healthy
    # Every secret referenced as ${VAR} in config.jsonc is provided here.
    env_file:
      - .env
    environment:
      # Derive the connection string from the same .env secret the database uses.
      DB_CONNECTION_STRING: "Host=postgres;Port=5432;Database=procul;Username=procul;Password=${POSTGRES_PASSWORD}"
      # Optional: the image defaults to config.jsonc next to the app (/app/config.jsonc).
      PROCUL_CONFIG_PATH: /app/config.jsonc
    ports:
      - "8080:8080"
    volumes:
      - ./config.jsonc:/app/config.jsonc:ro
    healthcheck:
      # The runtime image ships neither curl nor wget, so probe /health with bash's /dev/tcp.
      test:
        - CMD
        - bash
        - -c
        - >-
          exec 3<>/dev/tcp/127.0.0.1/8080 &&
          printf 'GET /health HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n' >&3 &&
          grep -q '"status":"healthy"' <&3
      interval: 30s
      timeout: 5s
      retries: 3
      start_period: 30s

volumes:
  postgres_data:
```

`config.jsonc` — a minimal, working config (see [`configuration.md`](configuration.md) for every
field):

```jsonc
{
  "$schema": "./config.schema.json",

  "server": {
    // A Flutter *web* client must list its origin here. Native clients ignore CORS.
    "corsAllowedOrigins": ["https://app.example.com"],
    "sessionLifetime": "30d"
  },

  "database": { "connectionString": "${DB_CONNECTION_STRING}" },

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
      "healthCheck": true
    }
  ],

  "modelHealth": { "enabled": true },
  "mcp": { "enabled": true }
}
```

Notice that `config.jsonc` contains **no secrets** — only `${VAR}` references that resolve from the
container environment (populated by `env_file`). That is why the file can be committed/mounted
read-only safely.

---

## Secrets via `.env`

<details>
<summary><strong>Which variables go where, and how substitution works</strong></summary>

Two things read `.env`:

1. **Compose itself** substitutes `${...}` in `compose.yaml` from a `.env` file in the project
   directory (or, for deployment, from the shell environment / `--env-file`).
2. **`env_file: .env`** passes the same variables into the `api` container, where the backend's
   loader resolves the `${VAR}` references inside `config.jsonc`.

So a single `.env` covers both. The variables the backend needs:

| Variable | Referenced by | Required |
| -------- | ------------- | -------- |
| `PROCUL_API_PASSWORD` | the app directly (not via config) | **yes** — startup fails without it |
| `OPENROUTER_KEY` | `config.jsonc` → `models[].apiKey` | for the example config |
| `S3_*` | `config.jsonc` → `attachments.s3.*` | only when `storage: "s3"` |
| `GITHUB_MCP_TOKEN` | `config.jsonc` → `mcpServers.*.headers` | only for that example server |
| `POSTGRES_PASSWORD` | `compose.yaml` (both services) | **yes** for this compose file |

**Do not commit `.env`.** For production, prefer your orchestrator's secret mechanism or
`docker compose --env-file /run/secrets/procul.env up -d`, and restrict file permissions
(`chmod 600`).

**Which variables does the container actually need?** Only the ones `config.jsonc` references (as
`${VAR}`), plus `PROCUL_API_PASSWORD`. The backend's loader fails fast and **names** any missing
variable, so a mistyped secret is caught at startup:

```
Config file '/app/config.jsonc' references environment variable 'OPENROUTER_KEY'
(in 'apiKey'), which is not set.
```

</details>

## Attachments on MinIO / S3

<details>
<summary><strong>Store attachment bytes in object storage instead of PostgreSQL</strong></summary>

By default attachment **bytes** live in a PostgreSQL `bytea` table. To use S3-compatible storage,
set `attachments.storage` to `"s3"` and fill in `attachments.s3` (see
[`configuration.md`](configuration.md#attachments)), then add MinIO to `compose.yaml`:

```yaml
  minio:
    image: minio/minio
    restart: unless-stopped
    command: server /data --console-address ":9001"
    environment:
      MINIO_ROOT_USER: ${S3_ACCESS_KEY:?set S3_ACCESS_KEY in .env}
      MINIO_ROOT_PASSWORD: ${S3_SECRET_KEY:?set S3_SECRET_KEY in .env}
    ports:
      - "9000:9000"   # S3 API
      - "9001:9001"   # web console
    volumes:
      - minio_data:/data
    healthcheck:
      test: ["CMD", "mc", "ready", "local"]
      interval: 10s
      timeout: 5s
      retries: 5
```

Add `minio_data:` to `volumes:`, and extend `.env`:

```bash
S3_BUCKET=procul-attachments
S3_REGION=us-east-1                 # any value; MinIO ignores it
S3_ENDPOINT=http://minio:9000       # container-to-container, so use the service name
S3_ACCESS_KEY=minioadmin
S3_SECRET_KEY=minioadmin
```

`config.jsonc`:

```jsonc
"attachments": {
  "storage": "s3",
  "s3": {
    "bucket": "${S3_BUCKET}",
    "region": "${S3_REGION}",
    "serviceUrl": "${S3_ENDPOINT}",
    "forcePathStyle": true,
    "accessKey": "${S3_ACCESS_KEY}",
    "secretKey": "${S3_SECRET_KEY}"
  }
}
```

**Gotchas**

- `forcePathStyle: true` is required for MinIO (path-style addressing).
- `serviceUrl` must be reachable **from inside the `api` container** — use the compose service
  name (`http://minio:9000`), not `localhost`.
- The bucket must already exist (create it once in the MinIO console at `:9001`, or via `mc`).
- The `api` service should `depends_on: [minio]` (or the healthy condition) so the first request
  doesn't race bucket availability.

</details>

## Reverse proxy, TLS, and CORS

<details>
<summary><strong>Put the API behind HTTPS and wire a web client's origin</strong></summary>

Terminate TLS at a reverse proxy (Caddy, Traefik, nginx, ...) and forward to the `api` container's
port. A minimal Caddy front end:

```caddyfile
api.example.com {
    reverse_proxy api:8080
}
```

Then, in `compose.yaml`, join both services to a shared network and (optionally) stop publishing
`8080` publicly — the proxy reaches `api:8080` over the internal network:

```yaml
  api:
    # ...
    expose:
      - "8080"
    networks: [procul]
    # remove the `ports:` mapping to keep the API off the public internet
```

**CORS is separate from TLS.** If a **Flutter web** build calls the API from a different origin,
list that origin in `server.corsAllowedOrigins`:

```jsonc
"server": { "corsAllowedOrigins": ["https://app.example.com"] }
```

Rules the backend enforces:

- **Development only:** an empty list allows any origin (so `flutter run -d chrome` works). Never
  applies elsewhere.
- **All other environments:** only the listed origins are approved; there is **no wildcard**. A
  `*` or a malformed origin **fails startup** rather than silently blocking (or over-allowing).
- Attachment downloads expose `Content-Disposition` cross-origin so a browser can read the
  filename.
- Native desktop/mobile clients are **not** subject to CORS; you can leave the list empty for them.

The API uses a bearer token (no cookies), so credentials/`AllowCredentials` are never involved.

</details>

## Upgrading

<details>
<summary><strong>Move to a new image tag safely</strong></summary>

```bash
# Pick a tag in compose.yaml (e.g. :1.2.3), then:
docker compose pull
docker compose up -d
```

- **Pin a version in production.** Prefer an exact tag (`:1.2.3`) or a commit (`:sha-…`) over
  `:latest` so restarts are reproducible. `:1.2` / `:1` float and can change under you.
- **Migrations run on startup.** Every boot, the container applies pending EF Core migrations
  (creating the database if needed). Back up PostgreSQL first if a release notes a schema change.
- **Roll back** by setting the previous tag and running `docker compose up -d` again. Schema
  migrations are forward-only, so a rollback across a schema change may need a database restore.

</details>

## Troubleshooting

<details>
<summary><strong>Common first-run problems</strong></summary>

- **The container exits immediately with a config error.** `config.jsonc` must be present and
  mounted: the image ships only `config.jsonc.example`, not a real config. Check the log — the
  loader names the missing file or the unresolved `${VAR}`.
- **"references environment variable 'X' … which is not set."** Add `X` to `.env` (or the shell
  environment / `--env-file`). `env_file` only helps if the file is in the compose project
  directory.
- **`PROCUL_API_PASSWORD` is not set.** It is required and is **not** read from `config.jsonc`.
- **Migrations run on startup.** There is no separate step; the app creates the schema. If the
  database is unreachable the app fails to start — check the `postgres` healthcheck and that
  `DB_CONNECTION_STRING` points at the `postgres` **service name**, not `localhost`.
- **`exec format error` / very slow start on Apple Silicon.** The image is `linux/amd64`; run it
  under emulation or build locally.
- **A web client is blocked by CORS.** Set `server.corsAllowedOrigins` to the exact origin the
  browser loads the app from (scheme + host + port), then recreate the container.
- **The API is not reachable.** The container listens on `8080`; map it (`ports: ["8080:8080"]`)
  or route through a reverse proxy. The image is env-agnostic — every setting is injected at run
  time.
- **The image is effectively read-only.** It runs as the non-root `app` user; anything that needs
  to persist belongs in PostgreSQL or S3, not the container filesystem.

</details>

## Related pages

- **[`configuration.md`](configuration.md)** — every `config.jsonc` field and the `${VAR}` rule.
- **[`../backend/AGENTS.md`](../backend/AGENTS.md#container-image--ci)** — how the image is built
  and published.
