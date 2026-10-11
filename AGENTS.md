# AGENTS.md — Procul (repo root)

> **This is the front door.** It orients you, states the standing rules, and points to the deeper
> documents. Each major area has its own, much more detailed `AGENTS.md` — read the relevant one
> before editing code there, and **keep every doc in sync when you change structure, conventions,
> commands, or gotchas.** A stale `AGENTS.md` or `docs/` page is worse than none.

## What this project is

**Procul** is a small, ChatGPT-style chat app — a demonstration of AI-assisted ("vibe")
development. It has two halves:

- **`backend/`** — a .NET 10 / ASP.NET Core minimal-API service. It stores conversations in
  PostgreSQL (EF Core), streams assistant replies over Server-Sent Events (SSE), calls the model
  through `Microsoft.Extensions.AI`, supports **multiple configured models** (one client each,
  selected per conversation), runs agent tools (current time + a sandboxed Python interpreter),
  connects to remote **MCP** tool servers, tracks **token usage**, stores/serves **file
  attachments** (PostgreSQL or S3), and supports **editing a user message** (destructive in v1).
  Configuration lives in a single `config.jsonc`; only secrets and the config path are environment
  variables.
- **`frontend/`** — a Flutter client (Linux desktop, web, mobile) with multiple conversations,
  streaming replies, **message editing**, tool-activity display, Markdown rendering, a **model
  picker** and a **Models** catalog screen, **file attachments** with inline image rendering, a
  **token-usage dashboard**, and multiple saved server profiles behind a shared-password sign-in.

The project is explicitly a demonstration, not a hardened product — read the code before trusting
it. See the top-level `README.md` for the human-facing overview.

## Read order (start here)

Pick the path that matches your task — you do not need to read everything.

1. **Any change** → this file (rules, layout, timeouts) → then the area's `AGENTS.md`.
2. **Backend code** → [`backend/AGENTS.md`](backend/AGENTS.md) — architecture, contracts, gotchas.
3. **Frontend code** → [`frontend/AGENTS.md`](frontend/AGENTS.md).
4. **`config.jsonc` shape** → [`docs/configuration.md`](docs/configuration.md).
5. **Deploying the backend** → [`docs/docker-compose.md`](docs/docker-compose.md).
6. **Building the client** → [`docs/flutter-builds.md`](docs/flutter-builds.md).

## Repository layout

| Path | What |
| ---- | ---- |
| `README.md` | Human-facing overview: features, getting started, configuration, container usage |
| `justfile` | Root task runner (**`just` modules**): `just backend …`, `just frontend …`, `just check` |
| `docs/` | Operator guides: `docker-compose.md`, `flutter-builds.md`, `configuration.md` |
| `backend/AGENTS.md` | **Backend conventions & gotchas** — architecture, config, endpoints, tests |
| `frontend/AGENTS.md` | **Frontend conventions & gotchas** — Flutter structure, state, API client, tests |
| `backend/justfile` | Backend recipes (`build`, `test`, `run`, `dev-db-*`, `docker-*`, `publish`) |
| `frontend/justfile` | Frontend recipes (`get`, `analyze`, `test`, `format`, `run`, `build-<platform>`) |
| `backend/src/Procul.Api/` | The API project (endpoints, services, entities, migrations) |
| `backend/tests/Procul.Api.Tests/` | xUnit unit + integration tests |
| `frontend/lib/` | Flutter app + `src/` (API client, controllers, UI) |
| `assets/`, `.github/workflows/` | Logo; CI + container publishing |

Each of `backend/` and `frontend/` has its own **`AGENTS.md`** with the detailed architecture,
conventions, and hard-won gotchas. Those are authoritative for their area; this file is general
guidance.

## Tech stack

| Layer    | Technology |
| -------- | ---------- |
| Backend  | .NET 10, ASP.NET Core minimal APIs, EF Core 10 + Npgsql, `Microsoft.Extensions.AI`, `Asp.Versioning`, `ModelContextProtocol`, `Lokad.Lython` |
| Database | PostgreSQL |
| Frontend | Flutter (Dart 3), `shadcn_flutter`, `gpt_markdown`, `google_fonts`, `fl_chart`, `file_picker`, `package:http`, `flutter_secure_storage` |
| Model    | OpenRouter (or any OpenAI-compatible endpoint you configure) |
| Tooling  | [`just`](https://github.com/casey/just) (≥ 1.0, for its modules), Docker/Compose, GitHub Actions |
| CI/CD    | GitHub Actions, Docker Buildx, GitHub Container Registry (`ghcr.io`) |

## Where to look for what

| If you are… | Read |
| ----------- | ---- |
| Shipping/deploying the backend | [`docs/docker-compose.md`](docs/docker-compose.md) |
| Building the Flutter client | [`docs/flutter-builds.md`](docs/flutter-builds.md) |
| Changing `config.jsonc` | [`docs/configuration.md`](docs/configuration.md) and `backend/AGENTS.md` |
| Touching backend code | `backend/AGENTS.md` |
| Touching frontend code | `frontend/AGENTS.md` |

## Working agreements (standing rules)

- **Start a new branch at the start of each implementation** (e.g. `feat/...`, `fix/...`,
  `chore/...`).
- **Commit your work, then ASK before pushing.** Never push without explicit confirmation.
- **Keep the docs fresh in the same change.** If you alter structure, conventions, commands, the
  config shape, the image name/tags, or the build steps, update the matching `AGENTS.md` **and**
  the relevant `docs/` page together.
- Keep changes consistent with the surrounding code's structure, naming, and style.
- Treat unfamiliar files or changes as potential user work; investigate before deleting or
  overwriting them.
- Don't commit secrets. `.env` is git-ignored; document the shape in `.env.example`.

## Running things

The root `justfile` wires up both halves as **modules**:

```bash
just --list                 # root recipes
just --list backend         # backend recipes
just --list frontend        # frontend recipes

just check                  # backend tests + frontend tests + frontend analyze
```

Under the hood (equivalently):

```bash
# Backend — no database or network needed for the test suite
cd backend
dotnet build Procul.slnx
dotnet test  Procul.slnx
just run                    # or: just dev-db-up && cd src/Procul.Api && dotnet run

# Frontend
cd frontend
flutter pub get
flutter analyze             # must stay clean
flutter test
```

See `backend/AGENTS.md` / `frontend/AGENTS.md` for per-area detail and `docs/` for deployment.

## ⚠️ Timeouts: do NOT set long ones

**Agents have a bad habit of setting very long timeouts "just in case" — don't.** Long timeouts
hide real hangs and waste the user's time.

- Start with a **short timeout** (about **15 seconds** is a good default for a command you expect
  to finish quickly — builds, `flutter analyze`, a single test, a file scan).
- If a command legitimately needs longer (a full `dotnet test`, a first `dotnet restore`, a
  container build), pick a sensible small value for *that* command and **increase incrementally**
  if it actually times out — e.g. 15s → 60s → 180s → 600s. Don't jump straight to an hour.
- Prefer running a **targeted** subset (one test, one project) over the whole suite while
  iterating, and only run the full suite once at the end.
- Background/long-running processes (dev servers, `docker compose up`) should be run in the
  background rather than with a huge timeout.
