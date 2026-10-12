# PLAN 3 — Tests, docs, verification & rollout

> **Audience:** the implementing agent. This is the **quality gate** for PLAN 1 (frontend) and PLAN 2
> (backend): the test matrix for every new feature **and** every regression in the screenshots, the
> responsive/display-ratio tests, the documentation updates, and the end-to-end verification. Read
> `AGENTS.md`, `backend/AGENTS.md`, `frontend/AGENTS.md` first.
>
> **Standing rules:** branch, commit, **ASK before pushing**; keep every `AGENTS.md` and `docs/` page in
> sync in the same change; **short timeouts**; `flutter analyze` clean + `dart format lib test`.

## 0. Definition of done

- `dotnet test backend/Procul.slnx` green (existing + new).
- `cd frontend && flutter analyze` clean and `flutter test` green (existing + new).
- `just check` (root) passes.
- New config fields are in **all** of `ProculConfig.cs`, `config.schema.json`, `config.jsonc.example`,
  `docs/configuration.md` and the validator.
- Every regression in the four screenshots has a **failing-before / passing-after** test.
- The relevant `AGENTS.md`/`docs/` pages describe the new behaviour.

## 1. Regression tests (the screenshots) — must exist

| # | Regression (screenshot) | Test | Assertion |
| --- | --- | --- | --- |
| R1 | Chat app bar overflows / paints over the title, and stretches to full height (S2, S4) | `test/responsive_layout_test.dart` | At 320×640 and 360×800 with a long title + ≥2 models: `takeException() == null`; title is 1 line; no trailing overflow; **the app bar height stays ~1 line (it does not grow to the screen height)** |
| R2 | Title wraps one char per line (S4) | `responsive_layout_test.dart` + `chat_management_test.dart` | Title `maxLines == 1` with ellipsis when constrained |
| R3 | Conversation-tile `…` does nothing (S3) | `test/conversation_menu_test.dart` | Tap `…` → Rename + Delete items found; Rename opens the dialog |
| R4 | Chat-header `…` does nothing (S4) | `test/chat_management_test.dart` | Tap header overflow → items found; Rename/Delete run |
| R5 | Sidebar refresh gives no feedback (S1) | `test/chat_management_test.dart` | A second list fetch is issued; busy state shown while in flight |
| R6 | Footer under the system nav bar (S3) | `test/responsive_layout_test.dart` | With synthetic `viewPadding.bottom = 34`, the sidebar bottom (tab row / list) and the composer clear it |
| R7 | Editing unreachable on touch (S4) | `test/chat_edit_test.dart` | Tap user bubble `…` → Edit → banner + prefilled text; submit calls the edit endpoint |
| R8 | Attachment image flicker (documented) | `test/chat_attachments_test.dart` | Rebuilding during a later stream does not reset a loaded image to the placeholder |
| R9 | Sidebar actions moved to a top tab row (new idea) | `test/home_shell_test.dart` | Usage/Models/Settings render as a tab row **above** the list with a `Divider` below it; the old footer is gone; tapping still opens the same screens; no overflow at 300 px |

## 2. Feature test matrix

### Frontend (widget + controller)

| Feature | Test file | Key assertions |
| --- | --- | --- |
| Attachment **sources** menu (Camera/Gallery/Files) | `test/attachment_upload_test.dart` | Entries match `AttachmentSources.available()` + model capabilities; **Camera hidden** when `supportsImageSource(camera)` is false (desktop/web); Video never offered |
| Camera capture | same | `pickFromCamera` bytes upload via the `FakeAttachmentPicker` seam |
| Gallery + Files **multi-upload** | same | N files upload; per-file failure keeps the rest; chips removable |
| **Infinite scroll up** | `test/chat_pagination_test.dart` | Near-top fetch uses `afterMessageId`; results prepend without duplication; stops on a short page |
| **Bottom pull-to-refresh** | `test/pull_to_refresh_test.dart` | `RefreshTriggerState.refresh()` reloads; disabled while `isStreaming` |
| Jump-to-latest pill (optional) | `test/chat_pagination_test.dart` | Appears when scrolled away; tap returns to offset 0 |
| **Per-response popover** | `test/token_usage_test.dart` | Shows that response's model/time/tokens only; "—" when unknown |
| Cross-device resume refresh + `409` | `test/chat_management_test.dart` | A `resumed` lifecycle event triggers `refreshAll`; skipped while editing/streaming; a `409` resyncs + toasts |
| Accent color | `test/app_theme_test.dart` | Both themes' `colorScheme.primary == Color(0xFFA832A0)` |
| App name / icon wiring | (config/static) | Display strings are "Procul Chat"; `flutter_launcher_icons` config present |

### Backend (unit + integration)

| Feature | Test file | Key assertions |
| --- | --- | --- |
| `generate_image` stores + links + emits `image` | `Chat/ImageGenerationToolTests.cs` | Bytes stored; attachment linked to the assistant message; `image` event; disabled config ⇒ tool absent |
| `show_image` URL + base64 | `Chat/ShowImageToolTests.cs` | Downloads/decodes, stores, emits; rejects non-image/oversized/`file:` URLs |
| Retention (default 14d) | `Attachments/MediaRetentionTests.cs` | Orphaned media (uploads + generated) deleted (metadata + bytes) after the window; referenced media keeps its row but its bytes are purged (`GET` 404s); `"0"` disables; bad duration fails fast |
| Per-response metadata | `Usage/UsageStreamingTests.cs`, `Integration/UsagePipelineTests.cs` | `TurnUsage.MessageId` set; history projection carries `model` + `usage`; `usage` SSE carries `model` |
| Optimistic concurrency | `Chat/ModelSelectionTests.cs`, `Integration/*PipelineTests.cs` | Stale `expectedRevision` ⇒ `409`; current ⇒ success; `Revision` bumps |
| Python isolation | `Chat/PythonSandboxTests.cs` (extend) | `open`/`os`/`subprocess`/`socket`/`pathlib` denied; step/time/output caps enforced |
| Attachment/model edge case | `Attachments/AttachmentTurnTests.cs` (extend) | A later turn on an incapable model sends the note and **no** `DataContent`; send gate still blocks new unsupported attachments |
| Config | `Configuration/ProculConfigLoaderTests.cs` (extend) | New sections validate; bad durations/slugs fail fast; schema accepts the example |

> Integration tests boot the real app with `WebApplicationFactory<Program>` and must set
> `PROCUL_API_PASSWORD` + `PROCUL_CONFIG_PATH` (see `Support/TestConfig`), replacing the DB with the
> in-memory provider and the model registry with fake clients (as `AttachmentPipelineTests` does).

## 3. Responsive / display-ratio tests (explicitly requested)

**File:** `test/responsive_layout_test.dart` (extend the existing one).

Build the shell across a matrix of sizes / aspect ratios and assert no overflow + reachability:

| Size | Device class | Assert |
| --- | --- | --- |
| 320×568 | small phone (16:9) | no overflow; composer + send + menu button reachable; title 1 line |
| 360×640 | phone | as above |
| 390×844 | tall phone (19.5:9) | as above |
| 412×915 | Android phone | as above |
| 768×1024 | tablet portrait | sidebar breakpoint behaviour |
| 1024×768 | tablet landscape | as above |
| 1400×900 | laptop | wide layout (sidebar + chat) |
| 2560×1440 | ultrawide | content column capped at `kContentMaxWidth` |

Also vary:
- **Text scale** (`MediaQuery.textScaler`): 1.0, 1.3, 2.0 — no overflow (a common real-world break).
- **Keyboard** (`viewInsets.bottom`): composer stays visible, list shrinks, no overflow.
- **`viewPadding.bottom`** (gesture nav): footer/composer clear it (R6).
- **Reduced motion** (`disableAnimations: true`): the UI still builds and interactions work.

Every case asserts `tester.takeException() == null` and that primary controls are hit-testable.

## 4. Docs to update (same change)

- **`frontend/AGENTS.md`**: attachment **sources** (camera/gallery/files) + `image_picker` + the
  `supportsImageSource` gate + multi-upload; reversed list + infinite scroll + **bottom pull-to-refresh**
  (and the `RefreshTrigger(reverse:)` gotcha); the message `…` menu + edit; per-response popover;
  lifecycle/periodic sync + `409` handling; accent color; app-name/icon setup; new deps.
- **`backend/AGENTS.md`**: `imageGeneration.*` + `attachments.retention`/`imageGeneration.retention`
  (default 14d); the per-turn tool factory;
  `generate_image`/`show_image`; the `image` SSE event; `TurnUsage.MessageId` + per-message usage;
  `Conversation.Revision` + `409`; the Python-isolation guarantees; updated API-surface table and config
  section list.
- **`docs/configuration.md`**: new sections/fields (`imageGeneration`, `attachments.retention` +
  `imageGeneration.retention`, default 14d), the `${VAR}` secrets table, durations.
- **`docs/flutter-builds.md`**: an "App icon" section with the PLAN 1 §P11 table (paths/resolutions/names)
  and the app-name notes.
- **`README.md`**: new feature bullets (image generation, show-image tool, media retention, camera/gallery,
  infinite scroll, per-response metadata, multi-device sync) and the config table rows.
- **Root `AGENTS.md`**: only if structure/commands changed (unlikely).

## 5. Verification (run at the end)

```bash
# from the repo root
just check                     # backend tests + frontend tests + frontend analyze

# individually
dotnet test backend/Procul.slnx
cd frontend && flutter analyze && flutter test && dart format lib test --set-exit-if-changed
```

Manual QA (dev DB + backend running):
1. **Regressions:** on a narrow phone (or 320-px surface), open a chat with a long title and ≥2 models —
   the app bar is clean and the title ellipsizes. Tap the tile `…` and header `…` — both open. Tap sidebar
   refresh — a spinner appears and the list refreshes. The footer clears the nav bar.
2. **Editing:** tap a user bubble `…` → Edit → change text → Save; the tail is replaced and a new reply streams.
3. **Attachments:** open the source menu (Camera on mobile only, Gallery, Files), multi-select, upload;
   take a photo. Switch to a model that can't read an earlier attachment; confirm the next reply still
   arrives and the model only saw a note.
4. **Scroll:** open a long chat; scroll up → older messages load with no jump; pull up at the bottom →
   refresh triggers (no need to reach the top).
5. **Images:** ask the model to generate an image (and to show one from a URL); the image appears in the
   chat, survives a reload, and is served from our own endpoint.
6. **Per-response info:** tap an assistant response → its model/time/tokens only; reload and confirm the same.
7. **Multi-device:** two clients; a change on one appears on the other after resume/refresh; a concurrent
   edit shows a friendly resync message rather than corrupting state.
8. **Branding:** the OS shows "Procul Chat" and the new icon; the accent is `#a832a0`.

## 6. Suggested implementation order (dependency-aware)

1. **Backend foundations** (PLAN 2 §B0 tool factory, §B4 per-response metadata, §B5 concurrency) with tests.
2. **Frontend regressions** (PLAN 1 §P1–P5).
3. **Frontend scroll** (§P7) and **attachment sources** (§P6).
4. **Backend media** (PLAN 2 §B1–B3) + client rendering of `image` events + the per-response popover (§P12).
5. **Branding/theme/icons** (§P8–P11).
6. **Sync** (§P13 + PLAN 2 §B5) and **hardening** (§B6–B7).
7. **Responsive test matrix**, docs, full verification.

## 7. Rollout notes

- The backend is additive: new config sections are optional. With none set, media retention defaults to
  **14 days** (orphaned media deleted; referenced media's bytes purged with metadata kept) and image
  generation is off. Operators who want to keep media forever set `attachments.retention`/
  `imageGeneration.retention` to `"0"`. Bump the image/`AGENTS.md` version notes.
- The client ships new deps (`image_picker`, `flutter_launcher_icons`); run `flutter pub get` and, for
  icons, `dart run flutter_launcher_icons` after the user supplies `assets/icon/icon.png`.
- If the backend isn't upgraded, the client degrades gracefully: hide image-generation UI when not
  advertised, and show live-only per-response info until §B4 lands.
