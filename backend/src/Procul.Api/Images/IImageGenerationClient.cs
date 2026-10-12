namespace Procul.Api.Images;

/// <summary>
/// The seam over an image-generation provider. Implementations target either OpenRouter's dedicated
/// Image API (<c>POST {baseUrl}/images</c>) or an OpenAI-compatible images endpoint
/// (<c>POST {baseUrl}/images/generations</c>).
/// </summary>
public interface IImageGenerationClient
{
    /// <summary>Generates one image. Throws <see cref="ImageGenerationException"/> on failure.</summary>
    Task<GeneratedImage> GenerateAsync(ImageGenerationRequest request, CancellationToken ct);
}

/// <summary>One generation request: a prompt plus optional reference images and output hints.</summary>
public sealed record ImageGenerationRequest(
    string Prompt,
    IReadOnlyList<ImageReference> References,
    string? Size,
    string? AspectRatio);

/// <summary>A reference image supplied to guide a generation.</summary>
public sealed record ImageReference(byte[] Bytes, string ContentType);

/// <summary>The decoded result: raw image bytes plus the reported media type.</summary>
public sealed record GeneratedImage(byte[] Bytes, string MediaType);

/// <summary>An image-generation call failed (bad status, malformed body, or no image returned).</summary>
public sealed class ImageGenerationException(string message) : Exception(message);
