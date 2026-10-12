namespace Procul.Api.Configuration;

/// <summary>
/// Image-generation settings, derived from <see cref="ProculConfig"/> at startup. Consumed by the
/// image-generation client, the <c>generate_image</c> tool, and the media-retention service.
/// </summary>
public sealed class ImageGenerationOptions
{
    /// <summary>Master switch. When false the tool is not offered and the prompt does not mention it.</summary>
    public required bool Enabled { get; init; }

    /// <summary><c>openrouter</c> or <c>openai-compatible</c> (already normalized to lower case).</summary>
    public required string Provider { get; init; }

    /// <summary>The provider base URL (absolute http(s)).</summary>
    public required string BaseUrl { get; init; }

    /// <summary>The API key (secret-resolved). Never returned by the API.</summary>
    public string? ApiKey { get; init; }

    /// <summary>The image-output model id.</summary>
    public required string Model { get; init; }

    /// <summary>Default image size when the model omits one.</summary>
    public required string DefaultSize { get; init; }

    /// <summary>Default aspect ratio when the model omits one.</summary>
    public required string DefaultAspectRatio { get; init; }

    /// <summary>Upper bound on reference images sent with a single generation.</summary>
    public required int MaxReferenceImages { get; init; }

    /// <summary>Per-request budget.</summary>
    public required TimeSpan Timeout { get; init; }

    /// <summary>
    /// Media age limit for generated/shown images. <see cref="TimeSpan.Zero"/> disables retention.
    /// When <c>imageGeneration.retention</c> is omitted, this inherits <c>attachments.retention</c>.
    /// </summary>
    public required TimeSpan Retention { get; init; }

    /// <summary>The default provider base URL when none is configured.</summary>
    public const string DefaultBaseUrl = "https://openrouter.ai/api/v1";

    /// <summary>The default image model when none is configured.</summary>
    public const string DefaultModel = "google/gemini-2.5-flash-image";

    /// <summary>Builds the options from the validated config.</summary>
    public static ImageGenerationOptions FromConfig(ProculConfig config)
    {
        var image = config.ImageGeneration;

        // The generated-image window inherits the upload window when it is not set explicitly.
        var uploadRetention = DurationParser.ParseRetention(
            config.Attachments.Retention, TimeSpan.FromDays(14), "attachments.retention");
        var retention = string.IsNullOrWhiteSpace(image.Retention)
            ? uploadRetention
            : DurationParser.ParseRetention(
                image.Retention, TimeSpan.FromDays(14), "imageGeneration.retention");

        return new ImageGenerationOptions
        {
            Enabled = image.Enabled,
            Provider = string.IsNullOrWhiteSpace(image.Provider)
                ? "openrouter"
                : image.Provider.Trim().ToLowerInvariant(),
            BaseUrl = string.IsNullOrWhiteSpace(image.BaseUrl)
                ? DefaultBaseUrl
                : image.BaseUrl!.Trim(),
            ApiKey = image.ApiKey,
            Model = string.IsNullOrWhiteSpace(image.Model) ? DefaultModel : image.Model!.Trim(),
            DefaultSize = string.IsNullOrWhiteSpace(image.DefaultSize) ? "1024x1024" : image.DefaultSize!.Trim(),
            DefaultAspectRatio = string.IsNullOrWhiteSpace(image.DefaultAspectRatio)
                ? "1:1"
                : image.DefaultAspectRatio!.Trim(),
            MaxReferenceImages = image.MaxReferenceImages,
            Timeout = DurationParser.Parse(image.Timeout, TimeSpan.FromSeconds(120), "imageGeneration.timeout"),
            Retention = retention,
        };
    }
}
