using Procul.Api.Configuration;

namespace Procul.Api.Tests.Support;

/// <summary>Builds <see cref="AttachmentOptions"/> for tests without a config file.</summary>
internal static class TestAttachmentOptions
{
    public static AttachmentOptions Create(
        string storage = "postgres",
        long maxFileSizeBytes = 20 * 1024 * 1024,
        IReadOnlyList<string>? allowed = null,
        bool resendHistory = false,
        long textInlineMaxBytes = 256 * 1024,
        S3AttachmentOptions? s3 = null) => new()
    {
        Storage = storage,
        MaxFileSizeBytes = maxFileSizeBytes,
        AllowedContentTypes = allowed ?? ["image/*", "text/*", "application/pdf", "audio/mpeg", "audio/wav"],
        ResendHistory = resendHistory,
        TextInlineMaxBytes = textInlineMaxBytes,
        S3 = s3,
    };
}
