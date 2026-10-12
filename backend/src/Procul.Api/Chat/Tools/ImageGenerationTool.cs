using System.ComponentModel;
using Microsoft.EntityFrameworkCore;
using Microsoft.Extensions.AI;
using Procul.Api.Attachments;
using Procul.Api.Configuration;
using Procul.Api.Images;
using ImageGenerationOptions = Procul.Api.Configuration.ImageGenerationOptions;
using ImageGenerationRequest = Procul.Api.Images.ImageGenerationRequest;

namespace Procul.Api.Chat.Tools;

/// <summary>
/// The <c>generate_image</c> tool: asks the configured image provider for an image, stores it as an
/// attachment, and surfaces it to the client via the <c>image</c> SSE event. Only offered when
/// <c>imageGeneration.enabled</c> is true. Provider errors are returned to the model as text so a
/// turn never fails because an image could not be produced.
/// </summary>
internal sealed class ImageGenerationTool(
    IImageGenerationClient client,
    ImageGenerationOptions options,
    TurnToolContext context,
    ILogger logger)
{
    public AIFunction Create() => AIFunctionFactory.Create(GenerateImageAsync, "generate_image");

    [Description("Generate an image from a text prompt. Optionally pass reference image attachment ids to guide it. " +
                 "The image is added to the chat. Use for creating/editing pictures, diagrams, illustrations.")]
    private async Task<string> GenerateImageAsync(
        [Description("A detailed description of the image to generate.")] string prompt,
        [Description("Optional attachment ids of reference images already in this conversation.")] Guid[]? referenceAttachmentIds = null,
        [Description("Optional size, e.g. \"1024x1024\" or a tier like \"2K\".")] string? size = null,
        [Description("Optional aspect ratio, e.g. \"16:9\", \"1:1\".")] string? aspectRatio = null,
        CancellationToken ct = default)
    {
        if (string.IsNullOrWhiteSpace(prompt))
        {
            return "A non-empty 'prompt' is required.";
        }

        try
        {
            var (references, referenceError) = await BuildReferencesAsync(referenceAttachmentIds, ct);
            if (referenceError is not null)
            {
                return referenceError;
            }

            var request = new ImageGenerationRequest(
                prompt.Trim(),
                references,
                string.IsNullOrWhiteSpace(size) ? options.DefaultSize : size!.Trim(),
                string.IsNullOrWhiteSpace(aspectRatio) ? options.DefaultAspectRatio : aspectRatio!.Trim());

            var image = await client.GenerateAsync(request, ct);

            if (image.Bytes.Length > context.AttachmentOptions.MaxFileSizeBytes)
            {
                return $"The generated image is too large ({image.Bytes.Length} bytes; the limit is " +
                       $"{context.AttachmentOptions.MaxFileSizeBytes} bytes).";
            }

            var fileName = $"generated-{DateTimeOffset.UtcNow:yyyyMMddHHmmss}.{ExtensionFor(image.MediaType)}";
            await ToolMedia.StoreAsync(context, image.Bytes, fileName, image.MediaType, ct);

            return $"Generated an image ({image.MediaType}, {image.Bytes.Length} bytes) and added it to the chat.";
        }
        catch (OperationCanceledException) when (ct.IsCancellationRequested)
        {
            throw;
        }
        catch (Exception ex)
        {
            logger.LogWarning(ex, "generate_image failed");
            return $"Image generation failed: {ex.Message}";
        }
    }

    private async Task<(IReadOnlyList<ImageReference> References, string? Error)> BuildReferencesAsync(
        Guid[]? referenceAttachmentIds,
        CancellationToken ct)
    {
        if (referenceAttachmentIds is not { Length: > 0 })
        {
            return ([], null);
        }

        var ids = referenceAttachmentIds.Distinct().ToList();
        var found = await context.Db.Attachments
            .Where(a => ids.Contains(a.Id))
            .ToListAsync(ct);

        var missing = ids.Except(found.Select(a => a.Id)).ToList();
        if (missing.Count > 0)
        {
            return ([], $"Unknown reference attachment id '{missing[0]}'.");
        }

        var nonImage = found.FirstOrDefault(a => !a.ContentType.StartsWith("image/", StringComparison.OrdinalIgnoreCase));
        if (nonImage is not null)
        {
            return ([], $"Reference '{nonImage.FileName}' is not an image ({nonImage.ContentType}).");
        }

        var limited = found.Take(Math.Max(0, options.MaxReferenceImages)).ToList();
        var references = new List<ImageReference>(limited.Count);
        foreach (var attachment in limited)
        {
            try
            {
                await using var stream = await context.Store.OpenReadAsync(attachment.StorageKey, ct);
                using var buffer = new MemoryStream();
                await stream.CopyToAsync(buffer, ct);
                references.Add(new ImageReference(buffer.ToArray(), attachment.ContentType));
            }
            catch (IOException)
            {
                // The bytes are gone (retention purged them); skip the reference rather than fail.
            }
        }

        return (references, null);
    }

    private static string ExtensionFor(string mediaType) => mediaType.Trim().ToLowerInvariant() switch
    {
        "image/png" => "png",
        "image/jpeg" or "image/jpg" => "jpg",
        "image/webp" => "webp",
        "image/gif" => "gif",
        "image/bmp" => "bmp",
        _ => "png",
    };
}
