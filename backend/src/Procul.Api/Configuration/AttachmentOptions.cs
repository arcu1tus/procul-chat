namespace Procul.Api.Configuration;

/// <summary>
/// Attachment upload settings, derived from <see cref="ProculConfig"/> at startup. Consumed by the
/// attachment endpoints, the store registration, and the streaming turn service (capability gate,
/// history re-send, and the text-inline cap).
/// </summary>
public sealed class AttachmentOptions
{
    /// <summary>Where attachment bytes are stored: <c>postgres</c> or <c>s3</c>.</summary>
    public required string Storage { get; init; }

    /// <summary>Largest attachment accepted, in bytes.</summary>
    public required long MaxFileSizeBytes { get; init; }

    /// <summary>Maximum distinct attachments on one submitted user message.</summary>
    public int MaxAttachmentsPerMessage { get; init; } = 20;

    /// <summary>Allowed content-type patterns (e.g. <c>image/*</c>).</summary>
    public required IReadOnlyList<string> AllowedContentTypes { get; init; }

    /// <summary>
    /// Whether earlier turns re-send attachment bytes, or only a text note. Defaults to
    /// <c>true</c> (see <see cref="AttachmentConfig.ResendHistory"/>).
    /// </summary>
    public required bool ResendHistory { get; init; }

    /// <summary>Cap, in bytes, on how much of a <c>text/*</c> file is inlined into the prompt.</summary>
    public required long TextInlineMaxBytes { get; init; }

    /// <summary>
    /// Media age limit for uploads. <see cref="TimeSpan.Zero"/> disables retention (keep forever).
    /// </summary>
    public required TimeSpan Retention { get; init; }

    /// <summary>S3-compatible storage settings; present only when <see cref="Storage"/> is <c>s3</c>.</summary>
    public S3AttachmentOptions? S3 { get; init; }

    /// <summary>Builds the options from the validated config.</summary>
    public static AttachmentOptions FromConfig(ProculConfig config) => new()
    {
        Storage = config.Attachments.Storage,
        MaxFileSizeBytes = config.Attachments.MaxFileSizeBytes,
        MaxAttachmentsPerMessage = config.Attachments.MaxAttachmentsPerMessage,
        AllowedContentTypes = config.Attachments.AllowedContentTypes,
        ResendHistory = config.Attachments.ResendHistory,
        TextInlineMaxBytes = config.Attachments.TextInlineMaxBytes,
        Retention = DurationParser.ParseRetention(
            config.Attachments.Retention, TimeSpan.FromDays(14), "attachments.retention"),
        S3 = config.Attachments.S3 is { } s3
            ? new S3AttachmentOptions
            {
                Bucket = s3.Bucket,
                Region = s3.Region,
                ServiceUrl = s3.ServiceUrl,
                ForcePathStyle = s3.ForcePathStyle,
                AccessKey = s3.AccessKey,
                SecretKey = s3.SecretKey,
            }
            : null,
    };

}

/// <summary>S3-compatible object-storage settings.</summary>
public sealed class S3AttachmentOptions
{
    public required string? Bucket { get; init; }
    public required string? Region { get; init; }
    public required string? ServiceUrl { get; init; }
    public required bool ForcePathStyle { get; init; }
    public required string? AccessKey { get; init; }
    public required string? SecretKey { get; init; }
}
