# AGENTS.md — Procul (repo root)

> **This file is for AI agents working in this repository.** It is the entry point. Each major
> area has its own, much more detailed `AGENTS.md` — read the relevant one before editing code
> there, and keep it up to date when you change structure, conventions, commands, or gotchas.

## What this project is

**Procul** is a small, ChatGPT-style chat app — a demonstration of AI-assisted ("vibe")
development. It has two halves:

- **`backend/`** — a .NET 10 / ASP.NET Core minimal-API service. It stores conversations in
  PostgreSQL (EF Core), streams assistant replies over Server-Sent Events (SSE), calls the model
  through `Microsoft.Extensions.AI`, supports multiple configured models, runs agent tools
  (current time + a sandboxed Python interpreter), connects to remote MCP tool servers, and
  tracks token usage. Configuration lives in a single `config.jsonc` (secrets stay in `.env`).
- **`frontend/`** — a Flutter client (Linux desktop, web, mobile) with multiple conversations,
  streaming replies, tool-activity display, Markdown rendering, a token-usage dashboard, and
  multiple saved server profiles behind a shared-password sign-in.

The project is explicitly a demonstration, not a hardened product — read the code before trusting
it. See the top-level `README.md` for the human-facing overview.

## Where to find things

| Path | What |
| ---- | ---- |
| `README.md` | Human-facing overview, features, getting started, configuration, container usage |
| `backend/AGENTS.md` | **Backend conventions & gotchas** — architecture, config, endpoints, tests |
| `frontend/AGENTS.md` | **Frontend conventions & gotchas** — Flutter structure, state, API client, tests |
| `backend/src/Procul.Api/` | The API project (endpoints, services, entities, migrations) |
| `backend/tests/Procul.Api.Tests/` | xUnit unit + integration tests |
| `frontend/lib/` | Flutter app + `src/` (API client, controllers, UI) |
| `assets/`, `.github/workflows/` | Logo; CI + container publishing |

If a task touches an area with its own `AGENTS.md`, treat that file as authoritative for that
area and this file as general guidance.

## Working agreements

- **Start a new branch at the start of each implementation** (e.g. `feat/...`, `fix/...`).
- **Commit your work, then ASK before pushing.** Never push without explicit confirmation.
- Keep changes consistent with the surrounding code's structure, naming, and style.
- Update the relevant `AGENTS.md` in the same change if you alter structure, conventions,
  commands, or gotchas. A stale `AGENTS.md` is worse than none.
- Treat unfamiliar files or changes as potential user work; investigate before deleting or
  overwriting.
- Don't commit secrets. `.env` is git-ignored; use `.env.example` to document the shape.

## Running things

```bash
# Backend (no database or network needed for the test suite)
cd backend
dotnet build Procul.slnx
dotnet test  Procul.slnx

# Frontend
cd frontend
flutter pub get
flutter analyze      # must stay clean
flutter test
```

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
