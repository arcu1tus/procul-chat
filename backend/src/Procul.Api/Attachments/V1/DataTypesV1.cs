namespace Procul.Api.Attachments.V1;

/// <summary>An uploaded attachment's metadata (never its bytes).</summary>
public sealed record AttachmentV1(
    Guid Id,
    string FileName,
    string ContentType,
    long SizeBytes,
    DateTimeOffset CreatedAt
);
