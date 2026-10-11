# PLAN4 — Docs, justfiles, AGENTS, CORS & polish

> **Series:** this is **Plan 4 of 4**. **Depends on Plans 1–3** (it documents their behavior and
> wires build/deploy tooling around the final shape). Start a **new branch** (`chore/docs-tooling`);
> commit without pushing; ask before pushing.

## Why this plan exists

Plans 1–3 change configuration, models, and attachments. This plan makes the project
**self-documenting and easy to build/deploy**: a `docs/` folder (Docker Compose from the `ghcr.io`
image + per-platform Flutter builds + a configuration reference), clean `justfile`s for both sides,
an overhauled root `AGENTS.md`, and a final CORS/README pass.

## Non-goals

- New features. Only docs, tooling, and small consistency fixes found while writing them.

---

## Part A — `docs/` folder

Create `docs/` with GitHub-flavored Markdown. Use `<details>`/`<summary>` collapsibles so long
platform sections are easy to navigate. Every page must be **verified against official docs** and
cross-linked.

### A1. `docs/README.md` (index)
- Short orientation + links to the three pages below and to `../README.md`.

### A2. `docs/docker-compose.md` — run the backend from the `ghcr.io` image
- The published image is `ghcr.io/<owner>/procul-chat/backend-api:<tag>` (from
  `.github/workflows/publish-backend-image.yml`).
- A complete `compose.yaml`: `postgres:alpine` + the backend image, `config.jsonc` bind-mounted
  read-only, secrets via `env_file`/`environment`, `healthcheck` on `GET /health`, a named volume,
  `restart: unless-stopped`, and the port mapping.
- `<details>` sections for: **secrets via `.env`**, **MinIO/S3 attachments**, **reverse proxy /
  TLS (CORS origins)**, **upgrading tags**, and **troubleshooting** (migrations run on startup; the
  image is env-agnostic; `config.jsonc` must be present).
- A worked example of `config.jsonc` (from Plan 1) with `${VAR}` secrets.

### A3. `docs/flutter-builds.md` — build the app for any platform
- Verified against the Flutter 3.47 deployment docs. A `<details>` block per platform with
  prerequisites, the exact command, the output path, and gotchas:
  - **Android** — `flutter build apk --release [--split-per-abi]` / `flutter build appbundle --release`;
    signing via `key.properties`; debug cleartext note.
  - **iOS** — `flutter build ipa` (macOS + Xcode only); signing.
  - **Linux** — `flutter build linux --release`; clang/cmake/ninja/GTK dev prerequisites.
  - **Windows** — `flutter build windows --release`; Visual Studio "Desktop development with C++".
  - **macOS** — `flutter build macos --release`; Xcode.
  - **Web** — `flutter build web --release` (`--wasm` opt-in; `--source-maps` note); serve
    `build/web`; **set `CORS_ALLOWED_ORIGINS` on the backend** to the web origin.
- The `--dart-define=PROCUL_API_BASE=https://api.example.com` pattern for every platform.

### A4. `docs/configuration.md` — the config reference
- Document every `config.jsonc` section (server, database, attachments, models, titleModel,
  modelHealth, mcp, mcpServers), the `${VAR}` secret rule, the JSON Schema file, and the one
  remaining env var (`PROCUL_CONFIG_PATH`) plus the secret env vars.
- Include the multi-model and capability/health semantics (from Plans 1–2).

## Part B — Justfiles

### B1. Root `justfile`
- Use `just` **modules**: `mod backend 'backend'`, `mod frontend 'frontend'` (plus a `default`
  recipe that runs `just --list` and prints a short help). Then `just backend test`,
  `just frontend build-web`, etc.
- Add a top-level `check` recipe that runs `just backend test` + `just frontend test` +
  `just frontend analyze`.

### B2. `frontend/justfile` (new)
- Variable `api := env_var_or_default('PROCUL_API_BASE', 'http://localhost:5010')`.
- Recipes with clear names:
  - `get` (`flutter pub get`), `analyze`, `test`, `format` (`dart format lib test`), `run` (linux).
  - `build-web`, `build-linux`, `build-windows`, `build-macos`, `build-android-apk`,
    `build-android-bundle`, `build-ios` — each passes `--dart-define=PROCUL_API_BASE={{api}}`.
  - `clean`.
- Document platform prerequisites in comments and link to `docs/flutter-builds.md`.

### B3. `backend/justfile` (move + clean up)
- Move `backend/src/Procul.Api/justfile` to `backend/justfile` with paths relative to `backend/`.
- Clearer names: `build`, `test`, `run` (dev), `dev-db-up`/`dev-db-down`/`dev-db-logs`,
  `docker-build`, `docker-run`, `publish` (`dotnet publish`), and `fmt` (`dotnet format`) if wanted.
- Update `backend/AGENTS.md` references and any README snippets.

## Part C — AGENTS.md overhaul

### C1. Root `AGENTS.md` (rewrite)
Currently two lines. Make it the project's front door:
- What Procul is (streaming tool-using chat; ASP.NET Core + Flutter).
- Repository layout, tech stack, the multi-model + attachments + MCP + usage features.
- Where the detailed conventions live (`backend/AGENTS.md`, `frontend/AGENTS.md`).
- **Point to `docs/`** and include a **"keep the docs and AGENTS.md up to date in the same change"**
  rule.
- The standing rules: start a branch per change; commit and **ask before pushing**.
- Build/test commands for both sides (from the justfiles).

### C2. `backend/AGENTS.md`
- Reflect Plans 1 & 3: the `Configuration/` module + config-as-source-of-truth, `ChatModelRegistry`,
  per-conversation model, `/v1/models`, `ModelCatalogService` + idle re-probe, the `Attachments/`
  module + stores + capability gate.
- Replace the env-var config table with the config.jsonc sections + the `PROCUL_CONFIG_PATH` /
  secret env vars.
- Point to `docs/configuration.md` and `docs/docker-compose.md`.

### C3. `frontend/AGENTS.md`
- Reflect Plans 2 & 3: model picker + Models screen + catalog controller, attachments + `file_picker`
  + `Image.memory`, and the new justfile commands.
- Point to `docs/flutter-builds.md`.

## Part D — CORS verification (multi-server)

- Re-read `Cors/CorsExtensions.cs` against the final config path (`server.corsAllowedOrigins`).
- Confirm the policy: dev with `[]` → any origin; otherwise exact origins; `*`/malformed → fail
  fast. Confirm `WithExposedHeaders("Content-Disposition")` (Plan 3) is present.
- Add/extend `Integration/CorsPipelineTests`: an allowed origin preflight for
  `POST /v1/attachments` and a `PUT /v1/conversations/{id}/model`; a disallowed origin in
  Production.
- Note in `docs/flutter-builds.md` that a web build needs its origin listed.

## Part E — README refresh

- Feature list: multi-model + per-conversation picker + Models screen; attachments (Postgres/S3).
- Repository layout: `docs/`, justfiles.
- Configuration section: point to `config.jsonc` + `docs/configuration.md` (drop the long env table).
- Container section: reference `docs/docker-compose.md`; show the `-v config.jsonc` + `-e` secrets
  pattern with the new config.

## Part F — Final verification

- `dotnet test backend/Procul.slnx` green; `flutter test` + `flutter analyze` clean;
  `dart format lib test`.
- `just --list` works from the root; `just backend test` and `just frontend test` succeed.
- Validate `config.jsonc.example` against `config.schema.json` (already covered by Plan 1 tests).
- Commit; **ask before pushing**.

## Behavior summary

1. `docs/` explains running the backend from the `ghcr.io` image and building the app for every
   platform, with collapsible, verified instructions.
2. Both sides have clean `justfile`s (root modules + per-side recipes).
3. `AGENTS.md` (root + both sides) is accurate, points at `docs/`, and mandates keeping docs fresh.
4. CORS is verified for the new endpoints.

## Assumptions / notes

- `just` modules require a reasonably recent `just` (≥ 1.0); documented as a prerequisite.
- Doc commands were cross-checked against the Flutter 3.47 deployment docs and the GitHub Container
  Registry / Docker Compose conventions at the time of writing.
