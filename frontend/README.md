# procul_chat_flutter

The Flutter client for **Procul**, a chat app. It supports multiple conversations
(list, switch, rename, delete), streams assistant replies over SSE, lets you edit an
earlier message (destructive in v1), shows tool activity, renders assistant Markdown,
attaches files (images render inline), picks the model per conversation, browses a
Models catalog, tracks token usage, and has a persisted settings dialog (dark mode by
default). It talks to the backend's versioned `/v1/conversations` API.

The backend lives in [`../backend`](../backend); its contract is documented in
[`../backend/AGENTS.md`](../backend/AGENTS.md). Per-platform build instructions are
in [`../docs/flutter-builds.md`](../docs/flutter-builds.md).

## Getting started

The backend must already be running (dev: `http://localhost:5010`).

```bash
flutter pub get
flutter run -d linux        # native Linux desktop
flutter run -d chrome       # web
```

The `justfile` wraps these (run from `frontend/`, or `just frontend <recipe>` from the
repo root):

```bash
just run                    # -d linux
just run-web                # -d chrome
just build-web | just build-linux | just build-android-apk | ...
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
