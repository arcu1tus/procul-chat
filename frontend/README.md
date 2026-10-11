# procul_chat_flutter

The Flutter client for **Procul**, a chat app. It supports multiple conversations
(list, switch, rename, delete), streams assistant replies over SSE, shows tool
activity, renders assistant Markdown, and has a persisted settings dialog (dark
mode by default). It talks to the backend's versioned `/v1/conversations` API.

The backend lives in [`../backend`](../backend); its contract is documented in
[`../backend/AGENTS.md`](../backend/AGENTS.md).

## Getting started

The backend must already be running (dev: `http://localhost:5010`).

```bash
flutter pub get
flutter run -d linux        # native Linux desktop
flutter run -d chrome       # web
```

The base URL defaults to `http://localhost:5010` and can be overridden without
editing code:

```bash
flutter run -d linux --dart-define=PROCUL_API_BASE=http://localhost:5010
```

## Development

```bash
flutter analyze             # must stay clean
flutter test                # unit + widget tests (no backend needed)
dart format lib test        # before committing
```

See [`AGENTS.md`](AGENTS.md) for the full architecture, conventions, and gotchas.
