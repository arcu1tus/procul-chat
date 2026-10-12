# Procul UI/UX overhaul — plan

Status: **approved — ready to implement.** Decisions confirmed (see the end).

## Intent

Make Procul feel like a polished, first-party AI client rather than a web app: a calm,
readable message surface, a single coherent motion language across every screen, unified
navigation, and layouts that adapt from a 320 px phone to an ultra-wide desktop. Keep the
existing architecture (shadcn_flutter, `ChangeNotifier`, one `ChatController`) and the
existing behavior/contracts intact.

Non-negotiables from the request:
- Rework the message box (remove the blank **user** avatar, cut the heavy stroke, adapt the
  bubble to a vertically-oriented phone).
- Fluid, intentional motion everywhere — never "an animation so there is one".
- A magical, unique streaming-text reveal (research first, then choose).
- Unify navigation: Settings must not be a popup while Usage/Models are full panes.
- Test everything, and prove it scales.

---

## Research: streaming-text animation (the "magical" reveal)

### How the good apps do it
- **ChatGPT / Claude** decouple *network* streaming from *visual* streaming: tokens are
  buffered and revealed at a steady cadence, so bursty SSE chunks still read as a smooth
  flow ("smooth streaming", e.g. Upstash's write-up: 5 ms/char ≈ 200 chars/s feels readable).
- The reveal is a **fade/materialize at the frontier**, plus a **pulsing caret**; sometimes a
  soft trailing gradient at the bottom edge that animates away on completion.
- Anthropic ships this in production; the effect is subtle but reads as "natural".

### Option A — adopt `flutter_streaming_text_markdown` (recommended engine)
- Purpose-built for LLM streams; **renders through `gpt_markdown`** (which we already use),
  so styling stays identical.
- Gives us, with constant memory:
  - `StreamPacing.catchUp()` — smooths bursty token arrival (the biggest fluidity win).
  - `RevealMode.smoothFade` — **paint-only per-word fade** (via `MarkdownFadeMask`) that does
    **not** rebuild `GptMarkdown` every frame (avoids the perf trap of naive per-char fades).
  - `trailingFadeEnabled` — bottom-edge gradient fade while streaming, animates away at end.
  - `showCursor`/`cursorColor` — pulsing dot caret; hidden on completion.
  - Reduced-motion + accessibility (single announcement, mid-stream text excluded).
  - Tolerates half-finished markdown (`**bol`, open fences) without flashing raw markers.
- Cost: a new dependency; must confirm it accepts `gpt_markdown ^1.3.4`. Our tests that
  assert `find.byType(GptMarkdown)` (3 spots) may need updating (the package likely still
  mounts a `GptMarkdown` internally — verify).
- We then layer a **Procul-specific glow** on top (see Option C) for the "unique" part.

### Option B — hand-roll a reveal widget (no new dependency, full control)
- Build `widgets/streaming_text.dart`: a pacer (buffer target text, advance a revealed count
  on a ticker) + a `ShaderMask` "frontier" gradient + an `ImageFiltered` blur bloom + a
  pulsing caret. Wrap the existing `GptMarkdown` (so tests and styling are untouched).
- Pro: no dependency, exact control, keeps `find.byType(GptMarkdown)`.
- Con: we must solve the perf problem ourselves (per-frame markdown reparse for long
  replies). Mitigate by revealing in word/chunk units, throttling the ticker, and using a
  `RepaintBoundary`; still weaker than the package's paint-only fade.

### Option C — the "unique" Procul layer (composable with A or B)
- **Frontier bloom**: a soft, accent-tinted (`#a832a0`) glow at the newest text, implemented
  as a `ShaderMask` gradient band (approximating reading order diagonally: newest ≈
  bottom-right of the growing block) plus a blurred duplicate layer for a true halo.
- **Ink-bloom caret**: a small pulsing dot tinted `primary`, replacing/alongside the cursor.
- **Accent desaturation**: brand tint kept *subtle* so it reads as a glow, not a highlighter.
- All of it behind the central reduced-motion gate.

**Recommendation (accepted):** Option A + C — adopt the package for the reveal engine
(robust, accessible, constant memory, markdown-safe) and add the Procul glow/bloom layer so
it feels bespoke. Fall back to Option B if the dependency doesn't fit `gpt_markdown ^1.3.4`.

---

## Workstream A — Message surface (the core ask)

Files: `lib/src/chat_screen.dart` (`_MessageBubble`, `_AssistantAvatar`, `_Avatar`,
`_AssistantText`, `_ShimmerText`, `_ThinkingDots`, `_Composer`, attachments), `widgets/`.

**Bubbles**
- **User**: right-aligned, filled rounded bubble on a *subtle* surface (`secondary`/a tuned
  muted tone) — **not** the saturated magenta `primary`; text in `foreground`. Radius ~18
  with a slightly tighter corner near the alignment edge. **No avatar on the user side.**
  Width capped by viewport (`min(680, viewport*0.75)` on desktop; ~90 % on phones).
- **Assistant**: drop the bubble fill and the `Border.all` — render markdown directly on the
  background (ChatGPT/Claude style), at the reading measure. **Keep an avatar** — a smaller,
  subtler brand mark (restyled from the current 30 px magenta circle) sitting at the top of
  the response. It stays **tappable** and keeps its existing behavior: pressing it opens the
  response-details popover (`Key('response-details')`, `_AssistantAvatar._showDetails`)
  showing **Model / Time / Input / Output / Cached / Total** tokens for that reply. Preserve
  the key, semantics (`Response details`) and tooltip so existing tests keep passing.
- **Action row** under each message (assistant: Copy; user: Edit / Copy), revealed with a
  fade+slide; hover-revealed on desktop, always available on touch. Reuse the existing
  `message-options` semantics/key. (Details stays on the assistant avatar, as today.)
- **Attachments + tool rows** restyled to match the lighter surface language (thinner borders,
  consistent radius).
- **Readability**: bump assistant line-height (~1.55), tune paragraph/list spacing, keep code
  blocks on GeistMono; ensure long code/lines don't force horizontal overflow on phones.
- **Empty state**: subtle animated brand mark + accent bar; staggered suggestion chips.

**Composer**
- Turn it into a single **rounded capsule surface** (attach · text field · send) with a subtle
  border/shadow and an **animated focus ring** — instead of today's bare `TextField` between
  loose icon buttons.
- Send is a circular primary button inside the capsule; enable/disable animates.
- Attachment chips + editing banner live inside/above the capsule with animated insets.
- Keep Enter/Shift+Enter semantics, touch detection, and the a11y labels
  (`Send message`, `Attach file`) that tests rely on.

---

## Workstream B — Motion system (every screen)

New file: `lib/src/motion.dart` (tokens + helpers), plus `widgets/pressable.dart`.

- **Tokens**: `Motion.fast` (~150 ms), `Motion.medium` (~240 ms), `Motion.slow` (~400 ms),
  a shared curve set (`easeOutCubic`, an emphasized curve, a spring for pops), and one
  central `reduceMotion(context)` used everywhere (replacing the ad-hoc checks).
- **Screen transitions (unified)**: wrap the main-pane Chat↔Usage↔Models↔Settings switch in
  a shared-axis fade+slide (`animations` package `SharedAxisTransition`/`FadeThrough`, or a
  hand-rolled equivalent) so panes cross-fade instead of snapping. The narrow sidebar slide
  uses the same tokens.
- **Menus**: standardize `showDropdown` with consistent `showDuration`/`dismissDuration`
  (shadcn already scale+fades popovers) and a shared menu theme (radius/shadow/padding);
  add a `showAppDialog` helper for consistent dialog motion.
- **Sidebar**: staggered list entrance, an animated selection highlight, hover lift, and an
  animated selected-tab background in the section row.
- **Buttons/inputs**: a `PressableScale` wrapper for press feedback on primary/outline/icon
  buttons; animated focus/hover rings on inputs.
- **Usage/Models**: staggered card entrance, animated stat count-up, fl_chart swap animation,
  a pulsing health dot while checking, and skeleton→content cross-fade.
- **Connect screen**: animated brand, staggered server tiles, form focus transitions.
- **Toasts/skeletons**: unify duration/curve; keep the existing shimmer but share one
  implementation and speed.
- Every non-essential animation gated by `Motion.reduceMotion`.

---

## Workstream C — Unify navigation (Settings as a pane)

Files: `settings_dialog.dart` → new `settings_screen.dart`, `home_shell.dart`,
`conversation_sidebar.dart`.

- Extract the Settings content (Appearance / Server / MCP) into `SettingsScreen` with the
  same `Scaffold`+`AppBar` treatment as Usage/Models (menu button on narrow screens).
- `HomeShell` gains `_showSettings`; the section enum gains `settings`; the sidebar tab row
  selects it and the shared transition covers all four panes. Chat stays mounted underneath
  (as Usage/Models already do) so scroll/buffer survive.
- Keep **modals** only where a modal is right: add-server, rename, delete/remove
  confirmations, toasts.
- Update `home_shell_test.dart` ("settings dialog switches the theme mode" → pane) and any
  `showSettingsDialog` call sites.

---

## Workstream D — Responsive scaling

- Introduce explicit breakpoints (`compact <600`, `medium 600–840`, `expanded ≥840`) in a
  small helper; today there is one 840 breakpoint and a separate 720 app-bar threshold.
- Drive from them: bubble/composer widths, paddings, font sizes, sidebar behavior, action
  visibility (hover vs touch), menu presentation.
- Clamp display-heading `TextScaler` so 2.0× text can't overflow the empty state/brand.
- Re-verify the full size/scale/reduced-motion matrix in `responsive_layout_test.dart`
  (and add the new bubble/composer assertions).

---

## Workstream E — Component polish (every box, input, button)

- Consistent surface tokens: one border weight, one radius scale, one shadow language.
- Restyle `CapabilityBadge`, `_TransportBadge`, `_UsageChip`, `_PickerButton`, `_JumpToLatest`,
  stat cards, and model cards to the new language (lighter strokes, tighter rhythm).
- `IconAction`: add the press-scale + hover treatment centrally.
- Empty/error/loading states: one shared visual pattern across chat/sidebar/usage/models/MCP.

---

## Workstream F — Tests

- Update existing: `home_shell_test` (GptMarkdown assertions if Option A; settings-pane),
  `chat_usage_test`/`chat_edit_test` (keys still valid), `responsive_layout_test`.
- New widget tests:
  - user bubble has **no avatar**; assistant **keeps** its tappable avatar whose popover still
    shows Model + Input/Output/Cached/Total tokens; assistant bubble has **no border**.
  - composer capsule builds, focus animation, send enable/disable, attachment chips.
  - Settings opens as a **pane** from the sidebar; section transitions don't throw.
  - streaming reveal: advances, completes, shows caret, and is **inert under reduced motion**.
  - motion tokens exist and durations/curves are used (light assertion).
  - responsive matrix across compact/medium/expanded incl. text scale 1.0/1.3/2.0.
- Keep `flutter analyze` clean and run `dart format lib test`.

---

## Workstream G — Docs

- Update `frontend/AGENTS.md`: new files (`motion.dart`, `settings_screen.dart`,
  `widgets/streaming_text.dart`, `widgets/pressable.dart`, `widgets/composer.dart`,
  `widgets/app_dialog.dart`), the motion conventions, the streaming-animation approach, the
  unified-navigation note, and any new gotchas (dependency version, test-key changes).
- Update `docs/flutter-builds.md` only if a dependency/command changes.

---

## Suggested sequencing

1. `motion.dart` + `PressableScale` + central reduced-motion (foundation).
2. Message surface: bubbles, action row, composer capsule.
3. Streaming reveal (A + C).
4. Unified navigation (Settings pane + section transitions).
5. Sidebar/Usage/Models/Connect polish + menus/dialogs.
6. Responsive pass + tests + docs.

## Risks

- **Dependency**: `flutter_streaming_text_markdown` must resolve against `gpt_markdown ^1.3.4`.
- **Test churn**: `find.byType(GptMarkdown)` assertions; mitigated if the package mounts it.
- **Performance**: avoid per-frame markdown reparse (why A's paint-only fade is attractive).
- **Scope**: large; phase it so each step lands green (`analyze` + tests).

## Decisions (confirmed)

1. **Streaming reveal: Option A + C.** Adopt `flutter_streaming_text_markdown` for the reveal
   engine, and layer the bespoke Procul accent glow/bloom (C) on top.
   - First implementation step: confirm it resolves against `gpt_markdown ^1.3.4`; if not,
     fall back to Option B.
2. **Avatars: assistant yes, user no.** The **user** bubble has no avatar. The **assistant**
   keeps a (restyled, subtler) avatar that remains tappable; pressing it shows which **model**
   generated the reply and its **token usage** (Model / Time / Input / Output / Cached /
   Total) — the existing `response-details` popover, preserved.
3. **Settings becomes a full pane.** Same `Scaffold`+`AppBar`/overlay treatment as Usage and
   Models, selected from the sidebar tab row; the dialog is dropped, while add-server and all
   confirmations stay modal.
