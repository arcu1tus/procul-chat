# PLAN 2 — Backend: image generation, media tools, retention, sync & hardening

> **Audience:** the coding agent (or human) implementing the backend/API work. Read `backend/AGENTS.md`
> first (architecture, config loader, SSE contract, gotchas). Client-visible UX is in **PLAN 1**;
> tests/docs/rollout in **PLAN 3**.
>
> **Standing rules:** branch (`feat/backend-media`); commit, then **ASK** before pushing; keep
> `backend/AGENTS.md` + `docs/configuration.md` + `config.schema.json` + `config.jsonc.example` in
> lockstep; **short timeouts**; keep `dotnet test Procul.slnx` green.

## 0. Context you must not break

- `config.jsonc` is loaded **once** at startup and is **fail-fast** (schema + domain validation). Every
  new section must be added to **all** of: `Configuration/ProculConfig.cs`, `config.schema.json`,
  `config.jsonc.example`, `docs/configuration.md`, and the domain validator in `ProculConfigLoader.cs`.
- SSE events are polymorphic records under `Chat/V1/ChatStreamEventsV1.cs`; the event kind is a `type`
  discriminator **inside** the JSON. Add a payload record + an envelope record; **no `[JsonDerivedType]`
  needed** (see gotchas).
- Tools today are **static singletons** (`AgentTools.All`). New tools that touch the DB/store/network
  per turn require a **per-turn tool factory** (§B0).
- Persistence rules: user message saved immediately; assistant reply after the stream; never hold a
  transaction across the model call. The **in-memory test provider** does not support
  `ExecuteUpdateAsync` — mutate tracked entities.
- `IAttachmentStore` owns the **bytes**; `Attachment`/`AttachmentBlob` own metadata. Bytes are **not**
  cascade-deleted — every removal path calls `IAttachmentStore.DeleteBytesAsync` first.

---

## B0 — Per-turn tool factory (prerequisite refactor)

**Why:** `generate_image` (§B1) and `show_image` (§B2) must store bytes, write DB rows, and emit an
`image` SSE event *during* the turn. A static `AIFunction` has no access to the scoped `ProculDbContext`
/ `IAttachmentStore` / the turn's event sink.

**Files:** `Chat/Tools/AgentTools.cs`, `Chat/V1/ChatStreamServiceV1.cs` (`MergeTools`), new
`Chat/Tools/TurnToolFactory.cs`, `Chat/Tools/TimeTool.cs`, `Chat/Tools/PythonSandbox.cs`.

**Approach**
- Keep `AgentTools.SystemPrompt` static; turn `All` into a factory:
  `IReadOnlyList<AITool> BuildTurnTools(TurnToolContext ctx, McpClientManager mcp)`, where
  `TurnToolContext` carries the scoped services (db, store, attachment options, image-generation options,
  an `IHttpClientFactory`, the resolved conversation/model, a `GeneratedMediaCollector`, and a sink to
  emit `image` events mid-stream).
- Convert `TimeTool`/`PythonSandbox` to `AIFunctionFactory.Create` **per turn** (or keep them static where
  they have no scoped deps; a uniform factory is simpler and removes the static list).
- `ChatStreamServiceV1.MergeTools` becomes an instance method that builds the turn tools and appends
  `mcp.Tools`.
- **Emitting mid-stream events from a tool.** The tool runs inside `UseFunctionInvocation()` and can't
  `yield` into the SSE enumerable. Use a small channel/queue: the tool enqueues `ChatStreamEventV1.Image(...)`;
  `StreamTokens` drains the queue after each update (it already scans `update.Contents`).
- **Linking generated media to the assistant message.** The assistant message doesn't exist during the
  tool call, so the collector holds the created `Attachment` rows; in `StreamReplyAsync`, after
  `db.ConversationMessages.Add(assistantMessage)` and before `SaveChangesAsync`, set
  `attachment.MessageId = assistantMessage.Id` so images survive a reload.

**Acceptance:** the built-in tools still work; generated/shown images show as attachments on the assistant
message; the SSE stream emits `image`.

---

## B1 — Image generation tool (`generate_image`)

**Goal:** the model can ask for an image (optionally with reference images) and it appears **in the chat
window**, generated through OpenRouter's Image API **or** an OpenAI-compatible images endpoint.

**Research (current):** OpenRouter now has a **dedicated Image API** (`POST {baseUrl}/images`) with
`{ model, prompt, input_references?, size?/resolution?/aspect_ratio?, n?, output_format?, ... }` returning
`data[0].b64_json` + `media_type`; new image models are added there only. Chat-completions image
generation still works for some models but is legacy. So the primary adapter targets `POST /images`; a
secondary adapter targets the OpenAI-compatible `POST /images/generations`
(`{ model, prompt, n, size, response_format: "b64_json" }` → `data[0].b64_json`).

**New config section** (POCO + schema + example + docs + validator):

```jsonc
"imageGeneration": {
  "enabled": false,
  "provider": "openrouter",                 // "openrouter" | "openai-compatible"
  "baseUrl": "https://openrouter.ai/api/v1",
  "apiKey": "${OPENROUTER_KEY}",            // ${VAR}; never returned
  "model": "google/gemini-2.5-flash-image", // an image-output model
  "defaultSize": "1024x1024",
  "defaultAspectRatio": "1:1",
  "maxReferenceImages": 4,
  "timeout": "120s",
  "retention": "14d"                        // how long generated/shown images are kept (§B3)
}
```

**New files**
- `Chat/Tools/ImageGenerationTool.cs` — the `generate_image` `AIFunction`.
- `Images/IImageGenerationClient.cs` — seam: `Task<GeneratedImage> GenerateAsync(ImageRequest, ct)`.
- `Images/OpenRouterImageClient.cs`, `Images/OpenAiCompatibleImageClient.cs`.
- `Images/ImageGenerationOptions.cs` (derived from config) + DI registration.

**Tool signature**

```csharp
[Description("Generate an image from a text prompt. Optionally pass reference image attachment ids to guide it. " +
             "The image is added to the chat. Use for creating/editing pictures, diagrams, illustrations.")]
Task<string> GenerateImageAsync(
    [Description("A detailed description of the image to generate.")] string prompt,
    [Description("Optional attachment ids of reference images already in this conversation.")] Guid[]? referenceAttachmentIds,
    [Description("Optional size, e.g. \"1024x1024\" or a tier like \"2K\".")] string? size,
    [Description("Optional aspect ratio, e.g. \"16:9\", \"1:1\".")] string? aspectRatio,
    CancellationToken ct);
```

**Behaviour**
1. If `imageGeneration.enabled` is false the tool is **not offered** (don't register it); the system prompt
   doesn't mention it.
2. Resolve reference images: load the `Attachment` rows, read bytes from the store, build base64 data URLs
   for `input_references` (OpenRouter) / the `image` array (OpenAI-compatible). Cap at
   `maxReferenceImages`; reject non-image refs.
3. Call the client (bounded by `timeout`); decode `data[0].b64_json` → bytes; use `media_type` for the
   content type (default `image/png`).
4. Validate size against a sane cap (reuse `attachments.maxFileSizeBytes`); store via `IAttachmentStore` as
   a new `Attachment` row (`generated-<timestamp>.<ext>`, `Sha256`). No `MessageId` yet — the collector
   links it after the reply is saved (§B0).
5. Return a short string to the model and enqueue a `ChatStreamEventV1.Image` for the client.
6. Errors (timeout, 4xx/5xx, no `b64_json`) return a clear message to the model (it can retry) and do
   **not** fail the turn.

**System prompt:** add a short conditional note that `generate_image` exists when enabled.

---

## B2 — Show-image tool (`show_image`)

**Goal:** the model can display an image **from a URL or raw bytes**; the backend downloads/decodes it,
stores it in the configured storage, and serves it from **our** endpoint.

**New file:** `Chat/Tools/ShowImageTool.cs` (uses the shared media-store helper from §B0/§B1).

**Tool signature**

```csharp
[Description("Display an image in the chat from a public URL or base64-encoded image bytes. " +
             "The image is downloaded/decoded and shown to the user.")]
Task<string> ShowImageAsync(
    [Description("A public http(s) URL of the image.")] string? url,
    [Description("Base64-encoded image bytes (with or without a data: prefix).")] string? base64,
    [Description("Optional file name to show.")] string? fileName,
    CancellationToken ct);
```

**Behaviour**
1. Exactly one of `url`/`base64` (else a clear error back to the model).
2. **URL path:** fetch with an `IHttpClientFactory` client (bounded timeout) with **SSRF guardrails** —
   only `http`/`https`, reject `file:`/`data:`/other schemes, cap the response size
   (`attachments.maxFileSizeBytes`), require `Content-Type: image/*` (or sniff magic bytes), and
   (recommended) block private/loopback/link-local IPs unless explicitly allowed. Re-check on redirects.
3. **Base64 path:** strip an optional `data:<type>;base64,` prefix, decode, infer the type from the prefix
   or magic bytes.
4. Store as an `Attachment` (via `IAttachmentStore`), enqueue an `image` event, return a short string.
5. Retention applies (§B3).

---

## B3 — Media retention (user uploads **and** generated/shown images)

**Finding:** there is **no** retention config today (confirmed — `attachments.*` has no TTL; the only
documented "known limitation" is orphaned uploads with no GC). This is new work.

**What "retention" means here (plain):** media currently lives forever. Retention is an age limit
(default **14 days**) after which the backend automatically cleans media up. There are two outcomes, both
driven by the **same** window:

1. **Orphaned media** (`MessageId == null` — uploaded but never sent, a failed send, or a generated/shown
   image from a turn that never persisted) is **deleted outright** (metadata + bytes). This is the
   "orphaned images that aren't needed anywhere should be gone" requirement, and it is **on by default**.
2. **Referenced media** (attached to a message) has its **bytes purged** but its **metadata kept**, so
   history still shows a "file expired" chip instead of a broken image (the client already degrades to a
   chip when `GET /v1/attachments/{id}` 404s). This is how long the bytes are *stored*.

A value of **`"0"` disables retention** (keep media forever). The window is per-category so uploads and
generated images can differ.

**Config** (`attachments.retention` + `imageGeneration.retention`; both default **`14d`**):

```jsonc
"attachments": {
  // ...existing...
  "retention": "14d"   // media age limit: orphans deleted, referenced bytes purged; "0" = keep forever
},
"imageGeneration": {
  // ...existing...
  "retention": "14d"   // same rule for generated/shown images; omit to inherit attachments.retention
}
```

> **Default choice:** **14 days** (inside the requested 7–30-day band). It is deliberately conservative —
> long enough that normal use never loses media, short enough that abandoned uploads and large generated
> images don't accumulate forever. Operators who want to keep media indefinitely set `"0"`.

**New files**
- `Attachments/MediaRetentionOptions.cs` (derived from config), `Attachments/MediaRetentionService.cs`
  (`IHostedService` background loop, e.g. hourly, over both the attachments table and the configured
  store): after the window, **delete** orphaned rows + bytes, and **purge bytes only** (keep the row) for
  referenced media. Must call `IAttachmentStore.DeleteBytesAsync` for every purge (S3 objects are not
  cascade-deleted).
- Extend `AttachmentConfig` (`Retention`), `ImageGenerationConfig` (`Retention`), `AttachmentOptions`,
  `ImageGenerationOptions`, `config.schema.json`, `config.jsonc.example`, `docs/configuration.md`,
  `backend/AGENTS.md`, and the domain validator (durations parse via `DurationParser`; `"0"` = disabled).

**"Update all the things" checklist (do not skip any)**
- `Configuration/ProculConfig.cs` — add `Retention` to `AttachmentConfig` + `ImageGenerationConfig`.
- `Configuration/AttachmentOptions.cs` / `ImageGenerationOptions.cs` — carry it.
- `config.schema.json` — `retention` (string) on both sections.
- `config.jsonc.example` — the new keys with comments.
- `docs/configuration.md` — the new fields + default + the orphan/referenced semantics.
- `backend/AGENTS.md` — the retention section + the known-limitation note ("orphaned uploads" is now
  handled).
- `README.md` — the config table row + a feature bullet.
- Tests (see PLAN 3): orphan delete, referenced byte-purge, `"0"` = disabled, bad duration fails fast.

**Tests:** orphaned media (both uploads and generated images) is deleted (metadata + bytes) after the
window; referenced media keeps its row but its bytes are gone (then `GET` 404s); `"0"` keeps everything;
a malformed duration fails startup; the job never touches media inside the window.

**Open question:** the exact default within 7–30 days (proposed **14d**); easy to change in one place.

---

## B4 — Per-response metadata (model + tokens per assistant message)

**Goal (drives PLAN 1 §P12):** the client can show, for **one** assistant response, its model, time, and
token usage — including for **historical** messages.

**Files:** `Chat/TurnUsage.cs`, `Chat/V1/ChatStreamServiceV1.cs`, `Chat/V1/ChatStreamEventsV1.cs`,
`Chat/V1/DataTypesV1.cs` (`ConversationMessageV1`), `Chat/V1/ChatEndpointsV1.cs`
(`GetConversationMessagesAsync`), `Infrastructure/DbContext.cs`, `Migrations/`.

**Approach**
- Add nullable `MessageId` to `TurnUsage` (indexed). In `StreamReplyAsync`, set
  `MessageId = assistantMessage.Id` when persisting the reply's usage. (Title rows keep it null.)
- Include `Model` + a `usage` object in `ConversationMessageV1` for assistant messages by projecting the
  matching `TurnUsage` row(s). Additive + camelCase.
- Add `Model` to the `usage` SSE event (`ChatStreamUsageV1`) so the live popover shows the model.
- Migration `AddTurnUsageMessageId` (design-time needs a valid config + `PROCUL_API_PASSWORD`).

---

## B5 — Multi-device consistency (optimistic concurrency)

**Goal (drives PLAN 1 §P13):** two clients on the same backend don't silently clobber each other.

**What "409" means here (plain):** each conversation gets a **revision number**. When a client edits, it
says "I'm editing revision 5". If the server is already at revision 6 (another device changed it), it
returns **HTTP 409 Conflict** instead of overwriting; the client refreshes and tells the user. 409 is just
the standard "your copy is stale" signal.

**Files:** `Chat/Conversation.cs`, `Chat/V1/ChatEndpointsV1.cs`, `Chat/V1/DataTypesV1.cs`,
`Infrastructure/DbContext.cs`, `Migrations/`.

**Approach (testable with the in-memory provider)**
- Add `Conversation.Revision` (int, default 0), incremented on every mutating save (send, edit, rename,
  set-model). Expose it in `ConversationV1`.
- Mutating endpoints accept an optional `expectedRevision`; on mismatch → **`409 Conflict`**. Send/edit are
  SSE, so validate the revision *before* starting the stream and return `409` as a normal JSON problem.
- Alternative rejected: Npgsql `xmin` concurrency tokens — unsupported by the in-memory provider used in
  tests.

---

## B6 — Python sandbox: verify & harden

**Files:** `Chat/Tools/PythonSandbox.cs`, tests under `Chat/`.

**Approach**
- **Audit** the current `DenyAllLythonHost` (already denies every file/path/process op; real clock; 5M
  execution steps; 5s wall-clock; 16 KiB stdout / 8 KiB stderr caps; small stdlib allowlist).
- **Add tests that prove isolation:** a script calling `open("/etc/passwd")`, `import os`, `subprocess`,
  `socket`, `pathlib` fails explicitly; a runaway loop hits the step/time cap; huge output is truncated.
- **Harden where cheap:** confirm the stdlib allowlist excludes `os`/`sys`/`socket`/`subprocess`/
  `importlib`; keep the fresh engine per call; keep the wall-clock + step caps; document the guarantees in
  `backend/AGENTS.md`.
- Consider (flag, don't necessarily ship) a per-request concurrency cap so simultaneous scripts can't
  exhaust CPU.

---

## B7 — Attachment/model capability edge case (verify + test + polish)

**Scenario (your words):** a user attaches a file and gets a reply; on a later turn they switch to a model
that **can't** read that file. The model should be told *an attachment existed* but receive **no bytes**.

**Finding:** this is **already implemented** — `AttachmentContentBuilder.Build` returns
`NotSentNote(attachment)` when `IsSupported` is false, and `BuildMessageContentAsync` applies the
**current** model's `capabilities` to every history attachment (`HistoryNote` when `resendHistory:false`).
So no bytes are sent. What's missing is **coverage** and **clarity**.

**Approach**
- Add explicit tests: attach under a capable model → switch to an incapable model → assert the request
  content contains the note and **no `DataContent`** for that attachment (both `resendHistory` values),
  using `RecordingChatClient`/`FakeChatClient`.
- Confirm the send gate still blocks *newly* attaching an unsupported file under the current model
  (`AttachmentGate.TypeProblem`).
- Optional client polish (PLAN 1): render a "not sent to this model" badge on such a chip (the client can
  compute it from the catalog + `attachmentRequiredModality`).

---

## B8 — Config/schema/DTO surface summary (keep everything in lockstep)

| Change | Files |
| --- | --- |
| `imageGeneration.*` | `ProculConfig.cs`, `config.schema.json`, `config.jsonc.example`, `docs/configuration.md`, validator, DI |
| `attachments.retention` + `imageGeneration.retention` (default `14d`) | same set + `AttachmentOptions`/`ImageGenerationOptions` |
| `Conversation.Revision` | entity, `DbContext`, `ConversationV1`, migration |
| `TurnUsage.MessageId` | entity, `DbContext`, migration, history projection |
| `usage` SSE gains `model` | `ChatStreamEventsV1.cs` |
| new `image` SSE event | `ChatStreamEventsV1.cs` + client (PLAN 1) |
| `.env.example` | only if a new secret is introduced (image gen can reuse `OPENROUTER_KEY`) |

## 0.1 API surface additions (update the table in `backend/AGENTS.md`)

| Method | Route | Notes |
| --- | --- | --- |
| `POST /v{version}/conversations/{id}/messages` | unchanged route; may stream `image` events, bumps `Revision`, accepts optional `expectedRevision` |
| `POST /v{version}/conversations/{id}/messages/{mid}/edit` | same; `409` on revision conflict |
| `PATCH /v{version}/conversations/{id}` | optional `expectedRevision`; `409` on conflict |
| `PUT /v{version}/conversations/{id}/model` | optional `expectedRevision`; `409` on conflict |
| `GET /v{version}/attachments/{id}` | may `404` after retention purged the bytes (metadata kept) |

## 1. Open questions (defaults apply if unanswered)

1. **B1 provider default:** OpenRouter `POST /images` (default) vs OpenAI-compatible `POST /images/generations`; ship **both**, config picks.
2. **B3 retention:** single window, default **14d** (orphans deleted; referenced bytes purged, metadata kept); `"0"` = keep forever.
3. **B5 conflict transport:** `409` + `expectedRevision` (default) vs `If-Match` ETag header.
4. **B2 SSRF policy:** block private/loopback IPs by default (recommended) — confirm.
