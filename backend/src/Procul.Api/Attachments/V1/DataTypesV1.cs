namespace Procul.Api.Attachments.V1;

/// <summary>An uploaded attachment's metadata (never its bytes).</summary>
public sealed record AttachmentV1(
    Guid Id,
    string FileName,
    string ContentType,
    long SizeBytes,
    DateTimeOffset CreatedAt
);

/// <summary>The configured upload policy, shared with authenticated clients.</summary>
public sealed record AttachmentPolicyV1(int MaxAttachmentsPerMessage, long MaxFileSizeBytes, IReadOnlyList<string> AllowedContentTypes);
