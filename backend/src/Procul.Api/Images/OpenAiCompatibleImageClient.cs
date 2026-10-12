using System.Text.Json.Nodes;
using Procul.Api.Configuration;

namespace Procul.Api.Images;

/// <summary>
/// An OpenAI-compatible images endpoint: <c>POST {baseUrl}/images/generations</c> with
/// <c>response_format: "b64_json"</c>. Reference images are sent in the <c>image</c> array as base64
/// data URLs; the response carries <c>data[0].b64_json</c>.
/// </summary>
internal sealed class OpenAiCompatibleImageClient(
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
            ["response_format"] = "b64_json",
        };

        var size = string.IsNullOrWhiteSpace(request.Size) ? Options.DefaultSize : request.Size;
        if (!string.IsNullOrWhiteSpace(size))
        {
            body["size"] = size;
        }

        if (request.References.Count > 0)
        {
            var images = new JsonArray();
            foreach (var reference in request.References)
            {
                images.Add(DataUrl(reference));
            }

            body["image"] = images;
        }

        var json = body.ToJsonString();
        using var document = await PostAsync("/images/generations", json, ct);
        return ReadFirstImage(document);
    }

    private static string DataUrl(ImageReference reference) =>
        $"data:{(string.IsNullOrWhiteSpace(reference.ContentType) ? "image/png" : reference.ContentType)};base64," +
        Convert.ToBase64String(reference.Bytes);
}
