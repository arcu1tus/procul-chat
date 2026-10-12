namespace Procul.Api.Images;

/// <summary>
/// Sniffs an image's magic bytes so a media type can be inferred even when a provider (or a URL
/// response) does not report one. Pure and dependency-free so it is trivially unit-testable.
/// </summary>
public static class ImageTypeDetector
{
    /// <summary>The default content type when nothing can be detected.</summary>
    public const string Fallback = "image/png";

    /// <summary>
    /// Detects the media type from the leading bytes, or returns <paramref name="fallback"/> when it
    /// is not a recognized image format.
    /// </summary>
    public static string Detect(ReadOnlySpan<byte> bytes, string? fallback = null)
    {
        var type = DetectOrNull(bytes);
        if (type is not null)
        {
            return type;
        }

        return string.IsNullOrWhiteSpace(fallback) ? Fallback : fallback!.Trim();
    }

    /// <summary>Detects the media type, or null when the bytes are not a recognized image.</summary>
    public static string? DetectOrNull(ReadOnlySpan<byte> bytes)
    {
        if (bytes.Length >= 8
            && bytes[0] == 0x89 && bytes[1] == 0x50 && bytes[2] == 0x4E && bytes[3] == 0x47
            && bytes[4] == 0x0D && bytes[5] == 0x0A && bytes[6] == 0x1A && bytes[7] == 0x0A)
        {
            return "image/png";
        }

        if (bytes.Length >= 3 && bytes[0] == 0xFF && bytes[1] == 0xD8 && bytes[2] == 0xFF)
        {
            return "image/jpeg";
        }

        if (bytes.Length >= 6
            && bytes[0] == 0x47 && bytes[1] == 0x49 && bytes[2] == 0x46
            && bytes[3] == 0x38 && (bytes[4] == 0x37 || bytes[4] == 0x39) && bytes[5] == 0x61)
        {
            return "image/gif";
        }

        if (bytes.Length >= 12
            && bytes[0] == 0x52 && bytes[1] == 0x49 && bytes[2] == 0x46 && bytes[3] == 0x46
            && bytes[8] == 0x57 && bytes[9] == 0x45 && bytes[10] == 0x42 && bytes[11] == 0x50)
        {
            return "image/webp";
        }

        if (bytes.Length >= 2 && bytes[0] == 0x42 && bytes[1] == 0x4D)
        {
            return "image/bmp";
        }

        return null;
    }

    /// <summary>Whether the bytes look like an image (used to reject a non-image URL response).</summary>
    public static bool LooksLikeImage(ReadOnlySpan<byte> bytes) => DetectOrNull(bytes) is not null;
}
