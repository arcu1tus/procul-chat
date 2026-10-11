# Deploying Procul on a VPS

An end-to-end walkthrough for a single **amd64** VPS: the backend and PostgreSQL in Docker
behind a **containerized Caddy**, then a **sideloaded Android APK** built on the same host.

This page is the assembly guide; it does not repeat the reference material:

- Container details (tags, upgrades, S3/MinIO, troubleshooting) live in
  [`docker-compose.md`](docker-compose.md).
- Every `config.jsonc` field lives in [`configuration.md`](configuration.md).
- Per-platform Flutter prerequisites and outputs live in
  [`flutter-builds.md`](flutter-builds.md).

## Prerequisites

- A **`linux/amd64`** host (`uname -m` → `x86_64`). The published image is `amd64` only; on an
  arm64 host build it from source (`docker build -f backend/src/Procul.Api/Dockerfile -t
  procul-api backend`) instead.
- Docker Engine with the Compose v2 plugin.
- A DNS record (e.g. `api.example.com`) pointing at the VPS, for Caddy to issue a certificate.
- An existing **Caddy running in Docker**. This page joins it to a shared Docker network and
  proxies to the `api` container by service name.
- For Part 2: the Procul repo checked out on the VPS and the Flutter/Android toolchain (installed
  in part 2 itself).

> **Why HTTPS is mandatory for the app.** Android blocks cleartext HTTP in release builds
> (API 28+). Caddy terminates TLS, so the release client talks HTTPS and the phone never needs a
> cleartext exception.

---

## Part 1 — backend behind Caddy

Everything lives in a dedicated directory such as `/opt/procul`, not in the git checkout.

### 1. A shared Docker network

Caddy and the API talk over a user-defined network, so the API never has to publish a port:

```bash
docker network create procul
```

Add the network to your **existing Caddy compose project** and join Caddy to it, then bring it up
again so it picks up the new network:

```yaml
services:
  caddy:
    # ...your existing config...
    networks: [procul]

networks:
  procul:
    external: true
```

Caddyfile:

```caddyfile
api.example.com {
    reverse_proxy api:8080
}
```

`api` resolves through Docker's embedded DNS because both services share the `procul` network.

### 2. `compose.yaml`

A self-contained `postgres:alpine` plus the published backend image. The API is exposed only to
the `procul` network — there is **no** public `ports:` mapping.

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
    networks: [procul]

  api:
    image: ghcr.io/arcu1tus/procul-chat/backend-api:1   # pin a tag in production
    restart: unless-stopped
    depends_on:
      postgres:
        condition: service_healthy
    env_file:
      - .env
    environment:
      # Derive the connection string from the same .env secret the database uses.
      DB_CONNECTION_STRING: "Host=postgres;Port=5432;Database=procul;Username=procul;Password=${POSTGRES_PASSWORD}"
      PROCUL_CONFIG_PATH: /app/config.jsonc
    expose:
      - "8080"                 # not published; only Caddy reaches it, over `procul`
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
    networks: [procul]

volumes:
  postgres_data:

networks:
  procul:
    external: true
```

### 3. `.env` (`chmod 600`, never commit)

```bash
POSTGRES_PASSWORD=$(openssl rand -base64 24)
PROCUL_API_PASSWORD=$(openssl rand -base64 32)   # the client's shared sign-in password
OPENROUTER_KEY=sk-or-v1-...
# GITHUB_MCP_TOKEN=...                              # only if you keep the example MCP server
```

`PROCUL_API_PASSWORD` is required and lives only here — never in `config.jsonc`. The
`DB_CONNECTION_STRING` is derived in compose from the same password, pointed at the `postgres`
service name.

### 4. `config.jsonc`

Copy [`../backend/src/Procul.Api/config.jsonc.example`](../backend/src/Procul.Api/config.jsonc.example)
and adjust at minimum:

```jsonc
{
  "$schema": "./config.schema.json",

  "server": {
    // A Flutter *web* client must list its origin here. Native Android ignores CORS.
    "corsAllowedOrigins": [],
    "sessionLifetime": "30d"
  },

  "database": { "connectionString": "${DB_CONNECTION_STRING}" },

  "attachments": {
    "storage": "postgres",
    "maxFileSizeBytes": 20971520,
    // An EMPTY list rejects every upload — set this explicitly.
    "allowedContentTypes": ["image/*", "text/*", "application/pdf", "audio/mpeg", "audio/wav"],
    "resendHistory": true,
    "textInlineMaxBytes": 262144
  },

  "models": [
    {
      "slug": "YOUR_REAL_MODEL_ID",   // sent verbatim as the model on the wire
      "name": "My model",
      "apiKey": "${OPENROUTER_KEY}",
      "baseUrl": "https://openrouter.ai/api/v1",
      "provider": "openrouter",
      "capabilities": ["text", "image"],
      "default": true,
      "healthCheck": true
    }
  ],

  "titleModel": "YOUR_REAL_MODEL_ID",
  "modelHealth": { "enabled": true },
  "mcp": { "enabled": true }
}
```

Two easy-to-miss items:

- The model **`slug` is the id sent to the provider**, not a display name. The example's
  `openrouter/free` is a placeholder — use a real id from
  [openrouter.ai/models](https://openrouter.ai/models).
- An **empty `allowedContentTypes` rejects every upload**; list the patterns you accept.

### 5. Start and verify

```bash
cd /opt/procul
docker compose up -d
docker compose logs -f api           # watch schema migrations on first boot
curl https://api.example.com/health  # -> {"status":"healthy"}
```

EF Core migrations are applied automatically at startup — there is no separate step. To upgrade
later, bump the pinned tag and run `docker compose pull && docker compose up -d` (migrations are
forward-only; back up PostgreSQL first).

---

## Part 2 — sideload an Android APK

Built **on the VPS**, headless. Android builds need no display.

The generated `android/app/build.gradle.kts` signs the `release` build with the **debug** key, so
no keystore is required for sideloading. (Trade-off: a debug-key-signed app cannot later be
upgraded in place by a Play Store build without uninstalling first. For store delivery, follow the
signing steps in [`flutter-builds.md`](flutter-builds.md#android).)

### 1. Toolchain (Debian/Ubuntu)

```bash
sudo apt-get update
sudo apt-get install -y curl git unzip xz-utils zip libglu1-mesa openjdk-17-jdk

# Flutter SDK (match your machine's stable channel; the docs are verified against 3.47)
cd ~ && git clone --depth 1 -b stable https://github.com/flutter/flutter.git
export PATH="$HOME/flutter/bin:$PATH"

# Android command-line tools — get the current URL from developer.android.com/studio
mkdir -p ~/android-sdk/cmdline-tools && cd ~/android-sdk/cmdline-tools
curl -O https://dl.google.com/android/repository/commandlinetools-linux-<VERSION>_latest.zip
unzip commandlinetools-linux-*.zip && mv cmdline-tools latest

export ANDROID_SDK_ROOT="$HOME/android-sdk"
export ANDROID_HOME="$HOME/android-sdk"
export PATH="$PATH:$ANDROID_SDK_ROOT/cmdline-tools/latest/bin:$ANDROID_SDK_ROOT/platform-tools"
```

Persist the exports in `~/.bashrc`, then let Flutter validate and accept licenses:

```bash
flutter doctor
flutter doctor --android-licenses
```

### 2. Build

```bash
cd ~/procul-chat/frontend
flutter pub get
flutter analyze
flutter build apk --release --dart-define=PROCUL_API_BASE=https://api.example.com
```

Artifact: `build/app/outputs/flutter-apk/app-release.apk` (a fat APK — simplest for sideloading).
Add `--split-per-abi` to get smaller per-ABI APKs
(`app-arm64-v8a-release.apk`, `app-armeabi-v7a-release.apk`, `app-x86_64-release.apk`).

> **`PROCUL_API_BASE` must be the HTTPS URL.** The value is compile-time and only pre-fills the
> Connect screen, but a release build blocks cleartext HTTP, so a plain-`http` backend fails on
> the device. See the [`PROCUL_API_BASE` pattern](flutter-builds.md#the-procul_api_base-pattern).

### 3. Install

```bash
scp you@vps:~/procul-chat/frontend/build/app/outputs/flutter-apk/app-release.apk .
adb install app-release.apk          # or copy the file over and tap it
```

Open the app: the Connect screen is pre-filled with `https://api.example.com`; enter
`PROCUL_API_PASSWORD` to sign in.

---

## Troubleshooting

<details>
<summary><strong>Common first-run problems</strong></summary>

- **`uname -m` is not `x86_64`.** The published image is `amd64` only — build it from source on
  the host, or run it under emulation.
- **The container exits with a config error.** `config.jsonc` must be present and mounted; the
  image ships only `config.jsonc.example`. The loader names the missing file or the unresolved
  `${VAR}`.
- **Caddy returns `502`.** The API is not on the same network as Caddy, or was started before the
  network was attached. Recreate both (`docker compose up -d`) and confirm `docker network
  inspect procul` lists both containers.
- **The app can't reach the backend.** Confirm `https://api.example.com/health` works in a
  browser, and that the APK was built with that exact origin (it is baked in at build time).
- **Uploads are rejected.** `attachments.allowedContentTypes` is empty or missing a pattern.

</details>

## Related pages

- [`docker-compose.md`](docker-compose.md) — the compose reference (tags, upgrades, S3/MinIO,
  TLS/CORS, troubleshooting).
- [`flutter-builds.md`](flutter-builds.md) — every platform, plus Android signing for the Play
  Store.
- [`configuration.md`](configuration.md) — every `config.jsonc` field and the `${VAR}` rule.
