namespace Procul.Api.Attachments;

/// <summary>
/// Metadata for a single uploaded file. The bytes live in the configured
/// <see cref="IAttachmentStore"/> (Postgres or S3) under <see cref="StorageKey"/>; this row is
/// always in Postgres so metadata queries never drag a blob.
///
/// <para>
/// <see cref="ConversationId"/>/<see cref="MessageId"/> are null until the file is attached to a
/// user message on send. An id referenced by a send request that is already attached is rejected.
/// </para>
/// </summary>
public class Attachment
{
    public Guid Id { get; set; } = Guid.CreateVersion7();

    /// <summary>The client's original file name (used for download and in prompt notes).</summary>
    public string FileName { get; set; } = "";

    /// <summary>The declared MIME type, e.g. <c>image/png</c>.</summary>
    public string ContentType { get; set; } = "application/octet-stream";

    /// <summary>The number of bytes stored.</summary>
    public long SizeBytes { get; set; }

    /// <summary>SHA-256 of the bytes, as lower-case hex (integrity / future dedupe).</summary>
    public string Sha256 { get; set; } = "";

    /// <summary>The key the store uses to locate the bytes.</summary>
    public string StorageKey { get; set; } = "";

    /// <summary>The conversation this attachment belongs to, once attached.</summary>
    public Guid? ConversationId { get; set; }

    /// <summary>The message this attachment is part of, once attached.</summary>
    public Guid? MessageId { get; set; }

    public DateTimeOffset CreatedAt { get; set; } = DateTimeOffset.UtcNow;
}

/// <summary>
/// The bytes of an attachment when <c>attachments.storage</c> is <c>postgres</c>. Kept in its own
/// table so metadata queries never load the blob. The <c>bytea</c> column is mapped by the
/// provider (Npgsql).
/// </summary>
public class AttachmentBlob
{
    /// <summary>The owning attachment (also the primary key).</summary>
    public Guid AttachmentId { get; set; }

    /// <summary>The raw file bytes.</summary>
    public byte[] Data { get; set; } = [];
}
