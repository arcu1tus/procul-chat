using System.Text.Json.Nodes;
using Procul.Api.Configuration;

namespace Procul.Api.Images;

/// <summary>
/// OpenRouter's dedicated Image API: <c>POST {baseUrl}/images</c>. Reference images are sent as
/// base64 data URLs in <c>input_references</c>; the response carries <c>data[0].b64_json</c> plus a
/// <c>media_type</c>.
/// </summary>
internal sealed class OpenRouterImageClient(
    IHttpClientFactory httpClientFactory,
    ImageGenerationOptions options)
    : HttpImageGenerationClient(httpClientFactory, options)
{
    public override async Task<GeneratedImage> GenerateAsync(ImageGenerationRequest request, CancellationToken ct)
    {
        var body = new JsonObject
        {
            ["model"] = Options.Model,
            ["prompt"] = request.Prompt,
            ["n"] = 1,
        };

        if (!string.IsNullOrWhiteSpace(request.Size))
        {
            body["size"] = request.Size;
        }

        if (!string.IsNullOrWhiteSpace(request.AspectRatio))
        {
            body["aspect_ratio"] = request.AspectRatio;
        }

        if (request.References.Count > 0)
        {
            var references = new JsonArray();
            foreach (var reference in request.References)
            {
                references.Add(DataUrl(reference));
            }

            body["input_references"] = references;
        }

        var json = body.ToJsonString();
        using var document = await PostAsync("/images", json, ct);
        return ReadFirstImage(document);
    }

    private static string DataUrl(ImageReference reference) =>
        $"data:{(string.IsNullOrWhiteSpace(reference.ContentType) ? "image/png" : reference.ContentType)};base64," +
        Convert.ToBase64String(reference.Bytes);
}
