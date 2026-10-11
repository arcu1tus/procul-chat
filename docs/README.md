# Procul documentation

Operator- and contributor-facing guides that go beyond the top-level [`README.md`](../README.md).
The README is the tour; these pages are the manuals.

| Page | What it covers |
| ---- | -------------- |
| [`docker-compose.md`](docker-compose.md) | Run the **backend** and PostgreSQL from the published `ghcr.io` image with Docker Compose: the full `compose.yaml`, secrets, S3/MinIO attachments, reverse-proxy/TLS CORS, upgrades, and troubleshooting. |
| [`flutter-builds.md`](flutter-builds.md) | Build the **Flutter client** for every platform (Android, iOS, Linux, Windows, macOS, web) with the exact commands, output paths, prerequisites, and the `PROCUL_API_BASE` dart-define pattern. |
| [`configuration.md`](configuration.md) | The complete **`config.jsonc` reference** — every section and field, defaults, the `${VAR}` secret rule, the JSON Schema, and the environment variables that live outside the file. |

## Where else to look

- **[`../README.md`](../README.md)** — what Procul is, the feature list, the tech stack, and a
  getting-started tour.
- **[`../backend/AGENTS.md`](../backend/AGENTS.md)** and
  **[`../frontend/AGENTS.md`](../frontend/AGENTS.md)** — the detailed architecture, conventions,
  and gotchas for each half (written for AI agents, but useful to humans too).
- **[`../backend/src/Procul.Api/config.jsonc.example`](../backend/src/Procul.Api/config.jsonc.example)**
  — a commented, ready-to-copy configuration file.

> **Keep these pages up to date.** If you change the config shape, the image name/tags, the build
> commands, or the CORS behavior, update the matching page in the same change. A stale doc is
> worse than none.
