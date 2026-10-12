using Procul.Api.Images;

namespace Procul.Api.Tests.Support;

/// <summary>
/// A deterministic <see cref="IImageGenerationClient"/> for tests: returns the supplied bytes (a
/// tiny PNG by default) and records the last request.
/// </summary>
internal sealed class FakeImageGenerationClient : IImageGenerationClient
{
    private static readonly byte[] TinyPng =
        [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x01, 0x02, 0x03, 0x04];

    private readonly byte[] _bytes;

    public FakeImageGenerationClient(byte[]? bytes = null, string mediaType = "image/png")
    {
        _bytes = bytes ?? TinyPng;
        MediaType = mediaType;
    }

    public string MediaType { get; }

    /// <summary>When set, <see cref="GenerateAsync"/> throws this.</summary>
    public Exception? ThrowOnCall { get; init; }

    /// <summary>The last request received.</summary>
    public ImageGenerationRequest? LastRequest { get; private set; }

    public int CallCount { get; private set; }

    public Task<GeneratedImage> GenerateAsync(ImageGenerationRequest request, CancellationToken ct)
    {
        CallCount++;
        LastRequest = request;

        return ThrowOnCall is not null
            ? Task.FromException<GeneratedImage>(ThrowOnCall)
            : Task.FromResult(new GeneratedImage(_bytes, MediaType));
    }
}
