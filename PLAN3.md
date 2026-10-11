# PLAN3 — Attachments end-to-end

> **Series:** this is **Plan 3 of 4**. **Depends on Plans 1 & 2** (models, capabilities,
> per-conversation model selection, the Models screen). Start a **new branch**
> (`feat/attachments`); commit without pushing; ask before pushing.

## Why this plan exists

Users want to attach files to a message — images, raw text, PDFs, and (where the model supports it)
audio — and have the model actually receive them. The backend must store the bytes somewhere
(Postgres **or** S3, config-selectable), associate them with a message, translate them into the
content types `Microsoft.Extensions.AI`/the OpenAI adapter understands, and refuse types the
selected model cannot read. The client needs a picker, previews, and rendering.

## Verified facts this plan relies on

- The OpenAI adapter (`Microsoft.Extensions.AI.OpenAI/OpenAIChatClient.cs`) maps:
  - `DataContent`/`UriContent` with an **image** media type → image part,
  - `DataContent` with **`audio/mpeg`/`audio/wav`** → input-audio part,
  - `DataContent` with **`application/pdf`** → file part, `HostedFileContent` → file part,
  - **everything else is dropped** (video is not mapped at all).
- OpenRouter chat completions accept only `text` + `image_url` content parts; its `architecture.input_modalities`
  (`text | image | file | audio | video`) is the capability source (Plan 1).
- `file_picker: ^13.1.0` supports Android/iOS/Linux/macOS/Web/Windows + Wasm, returns `PlatformFile`
  with `readAsBytes()`.

## Decisions (confirmed with the operator)

| Question | Choice |
| --- | --- |
| Storage | **Both Postgres `bytea` and S3, config-selectable** (`attachments.storage`) |
| Types sent to the model | **Images + raw text + PDF everywhere-capable; mp3/wav audio where supported; video stored + shown but not sent** |
| Gating | Capability-gated in the UI **and** enforced by the backend |

## Non-goals

- OCR / server-side PDF text extraction (a later plan if wanted).
- Video understanding (adapter can't; stored + rendered only).
- Virus scanning (note it as a hardening follow-up).

---

## Part A — Storage configuration (already in the Plan 1 schema)

`config.jsonc` → `attachments`:

```jsonc
"attachments": {
  "storage": "postgres",            // "postgres" | "s3"
  "maxFileSizeBytes": 20971520,
  "allowedContentTypes": ["image/*", "text/*", "application/pdf", "audio/mpeg", "audio/wav"],
  "resendHistory": false,           // false = only the newest user turn carries the bytes
  "textInlineMaxBytes": 262144,     // cap for inlining a text/* file into the prompt
  "s3": { "bucket": "${S3_BUCKET}", "region": "${S3_REGION}", "serviceUrl": "${S3_ENDPOINT}",
          "forcePathStyle": true, "accessKey": "${S3_ACCESS_KEY}", "secretKey": "${S3_SECRET_KEY}" }
}
```

`AttachmentOptions` is bound by the Plan 1 loader; Plan 3 consumes it. Add the **`AWSSDK.S3`**
NuGet package (S3 store only; MinIO/S3-compatible via `serviceUrl` + `forcePathStyle`).

## Part B — Data model

- **`Attachments/Attachment.cs`** entity:
  `Id` (Guid v7), `FileName`, `ContentType`, `SizeBytes`, `Sha256`, `StorageKey`,
  `ConversationId?`, `MessageId?`, `CreatedAt`.
  - Metadata always lives in Postgres; only the **bytes** go to the configured store.
  - `MessageId`/`ConversationId` are null until the attachment is attached on send.
  - FK `MessageId → ConversationMessage` with cascade delete; index on `MessageId`.
- **`ConversationMessage`** gains a navigation `List<Attachment> Attachments` (or a join if we
  prefer; a nullable FK is simpler here).
- **`ConversationMessageV1`** gains `List<AttachmentV1> Attachments` (empty for assistant/tool).
- EF migration `AddAttachments` (new table + FK + index).
- **Postgres store:** an `AttachmentBlobs` table (`AttachmentId` PK, `Data bytea`) so metadata
  queries don't drag blobs; or a `bytea` column on `Attachment` — prefer the separate table.

## Part C — Store abstraction

`Attachments/IAttachmentStore.cs`:

```csharp
public interface IAttachmentStore
{
    string Kind { get; } // "postgres" | "s3"
    Task<string> PutAsync(Stream content, string contentType, CancellationToken ct); // returns StorageKey
    Task<Stream> OpenReadAsync(string storageKey, CancellationToken ct);
    Task DeleteAsync(string storageKey, CancellationToken ct);
}
```

- `PostgresAttachmentStore` (default): writes/reads the `bytea` row.
- `S3AttachmentStore`: `AWSSDK.S3` `PutObjectAsync`/`GetObjectAsync`/`DeleteObjectAsync`;
  `AmazonS3Config { ServiceURL, ForcePathStyle }` when `serviceUrl` is set (MinIO), otherwise the
  region default; credentials from `accessKey`/`secretKey` (or the default chain when omitted).
- Registered by `attachments.storage`; both implementations share the same tests via the interface.
- Deletion is best-effort and idempotent.

## Part D — Endpoints (`Attachments/V1/AttachmentEndpointsV1.cs`)

```
POST   /v{version}/attachments        multipart/form-data (file field) → AttachmentV1 (201)
GET    /v{version}/attachments/{id}   bytes (Content-Type, Content-Disposition) — authenticated
DELETE /v{version}/attachments/{id}   204 (idempotent)
```

- **Validation:** reject when `SizeBytes > maxFileSizeBytes` (`413`) or `ContentType` not matched by
  `allowedContentTypes` (`400`). Match wildcards (`image/*`). Optionally sniff magic bytes to
  confirm the declared type (reject mismatches).
- `GET` streams from the store; sets `Content-Disposition: inline; filename="…"` and the stored
  content type. **CORS:** add `WithExposedHeaders("Content-Disposition")` to the policy so a web
  client can read the filename; the `Authorization` header already triggers (and is allowed by)
  preflight.
- Wire a `Attachments` versioned group in `Program.cs` (mirrors `Mcp`/`Usage`).

## Part E — Sending attachments with a message

- **DTOs:**
  - `CreateConversationRequestV1(string InitialMessage, string? Model, List<Guid>? AttachmentIds)`.
  - `SendMessageRequestV1(string Text, List<Guid>? AttachmentIds)`.
  - `AttachmentV1(Guid Id, string FileName, string ContentType, long SizeBytes, DateTimeOffset CreatedAt)`.
- **Flow** (in `ChatStreamServiceV1`):
  1. Load the referenced `Attachment` rows; 404/400 if any id is unknown or already attached.
  2. Resolve the conversation's model (Plan 1) and its **effective capabilities**.
  3. **Capability gate:** for each attachment, map its type → required capability; if the model
     doesn't support it, return a `400 Problem` naming the file and the missing capability. (Video
     and other unknown types are allowed to be *stored*, but are **not** sent — see below.)
  4. Attach the rows to the persisted user message (`MessageId`, `ConversationId`).
  5. Build the user `ChatMessage` content parts (Part F).
- **History rebuild:** by default (`resendHistory: false`) only the **current** user turn carries
  the bytes; earlier user messages with attachments contribute a short `TextContent` note
  (`[Attached file: name (type, N bytes)]`) so the model still knows they exist without re-sending
  large blobs every turn. `resendHistory: true` re-sends the bytes each turn.

## Part F — Attachment → `AIContent` mapping

`Attachments/AttachmentContentBuilder.cs` (pure, unit-testable). Given an attachment + the model's
effective capabilities, produce `IReadOnlyList<AIContent>`:

| Attachment type | Capability | Produced content |
| --- | --- | --- |
| `image/*` | `image` | `DataContent(bytes, contentType)` (adapter → image part) |
| `application/pdf` | `file` | `DataContent(bytes, "application/pdf") { Name = fileName }` (→ file part) |
| `audio/mpeg`, `audio/wav` | `audio` | `DataContent(bytes, contentType)` (→ input-audio part) |
| `text/*` (and a small configured allow-list) | `text` | `TextContent("--- file: name ---\n" + utf8)`, capped at `textInlineMaxBytes` |
| anything else / video | — | **not sent**; `TextContent("[Attached file: name (type, N bytes) — not sent to this model]")` |

- The user's text is always the first part (`TextContent(userText)`), then the attachment parts.
- If the model supports `image` and `file` and `audio`, multiple parts are emitted in order.

## Part G — CORS

- Confirm multipart + bearer preflight still passes (`AllowAnyHeader` already covers it).
- Add `WithExposedHeaders("Content-Disposition")`.
- Add a `CorsPipelineTests` case for an attachment upload from an allowed origin.
- Native clients unaffected.

## Part H — Frontend

- **Dependency:** `file_picker: ^13.1.0`.
- **`lib/src/attachments.dart`** (new): `Attachment` DTO (mirrors `AttachmentV1`).
- **`lib/src/chat_api.dart`:**
  - `Future<Attachment> uploadAttachment(Uint8List bytes, String fileName, String contentType)`
    via `http.MultipartRequest` (POST `/v1/attachments`).
  - `Future<Uint8List> fetchAttachmentBytes(String id)` (authenticated; used by `Image.memory`).
  - `deleteAttachment(id)`.
- **`lib/src/chat_controller.dart`:**
  - `pendingAttachments` (uploaded-but-not-sent) with add/remove; clears on send.
  - `send(text, {List<String> attachmentIds})`; `createConversation` includes ids.
  - Validate picks against the **active model's** capabilities (from Plan 2's catalog) and the
    configured limits; surface a friendly error for unsupported/too-large files.
- **Composer (`chat_screen.dart`):** a paperclip attach `IconAction`; on pick, upload with a small
  progress/`Skeleton` state; show removable preview chips (thumbnail for images, icon + name + size
  otherwise); disable attach while streaming.
- **Message rendering:** user bubbles show attachments — images via `Image.memory` (bytes fetched
  through `ChatApi` and cached), other files as chips (name/size, tap to save via `file_picker`
  `saveFile`). Reloaded history shows persisted attachments.
- Web caveat: an `<img>` tag cannot send the bearer token, so always fetch bytes through `ChatApi`
  and render `Image.memory` (works on web + desktop + mobile).

## Part I — Tests

### Backend
- `Attachments/AttachmentStoreTests`: the interface contract against **both** stores (Postgres via
  the in-memory EF provider for the metadata path + a fake for bytes; S3 against a fake/`AmazonS3`
  interface seam) — put/read/delete, missing key.
- `Attachments/AttachmentValidationTests`: size limit (413), disallowed content type (400),
  wildcard matching, magic-byte sniff (if implemented).
- `Attachments/AttachmentContentBuilderTests`: every row of the mapping table; unsupported type →
  text placeholder; text inline cap; capability gating throws/returns a problem.
- `Integration/AttachmentPipelineTests` (temp config + in-memory EF): auth on all three routes;
  upload → metadata; `GET` returns bytes + headers; delete idempotent; send a message with
  attachment ids → the streamed turn receives the expected content parts (via a fake `IChatClient`
  that captures the request); unsupported type → `400`.
- Migration applies.

### Frontend
- `test/attachment_upload_test.dart`: pick → upload → preview chip → remove; unsupported/too-large
  rejected with a message.
- `test/chat_attachments_test.dart`: send includes `attachmentIds`; images render via `Image.memory`
  (fake bytes); history shows attachments; chip download calls `saveFile`.
- Controller tests for `pendingAttachments` lifecycle.
- `flutter analyze` clean; `dart format lib test`.

## Part J — Docs & workflow

- `backend/AGENTS.md`: the `Attachments/` module, the store abstraction (Postgres + S3), the
  capability gate, the content mapping table, and the `resendHistory` behavior.
- `frontend/AGENTS.md`: `file_picker`, the composer attach flow, `Image.memory` rendering, and the
  authenticated byte fetch.
- `README.md`: attachments feature + the `attachments` config section; note the S3/MinIO option.
- `docs/` cross-links are finalized in Plan 4.
- Run `dotnet test`, `flutter test`, `flutter analyze`; commit; **ask before pushing**.

## Behavior summary

1. Users attach files; bytes land in Postgres or S3 (config choice), metadata in Postgres.
2. On send, the backend checks the model's capabilities and only sends what the model can read.
3. Images/text/PDF render and round-trip; audio works where supported; video is stored + shown but
   not sent.
4. Reloaded conversations show their attachments.

## Assumptions / notes

- There are **no users** (single shared password), so any authenticated client can fetch any
  attachment id. Acceptable for this app; note it as a hardening follow-up (signed URLs / ownership).
- Inlining text files and (optionally) re-sending history increases prompt tokens; the caps and
  `resendHistory: false` default bound it.
