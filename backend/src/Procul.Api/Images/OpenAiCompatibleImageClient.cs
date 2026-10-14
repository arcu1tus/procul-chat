using System.Text.Json.Nodes;
using System.Net.Http.Headers;
using Procul.Api.Configuration;

namespace Procul.Api.Images;

/// <summary>
/// An OpenAI-compatible images endpoint: <c>POST {baseUrl}/images/generations</c> with
/// base64 image responses. Reference images are sent as multipart files to <c>/images/edits</c>; the response carries <c>data[0].b64_json</c>.
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

        };

        var size = string.IsNullOrWhiteSpace(request.Size) ? Options.DefaultSize : request.Size;
        if (!string.IsNullOrWhiteSpace(size))
        {
            body["size"] = size;
        }

        if (request.References.Count > 0)
        {
            using var multipart = new MultipartFormDataContent();
            multipart.Add(new StringContent(Options.Model), "model");
            multipart.Add(new StringContent(request.Prompt), "prompt");
            multipart.Add(new StringContent("1"), "n");
            if (!string.IsNullOrWhiteSpace(size)) multipart.Add(new StringContent(size), "size");
            foreach (var (reference, index) in request.References.Select((r, i) => (r, i)))
            {
                var bytes = new ByteArrayContent(reference.Bytes);
                bytes.Headers.ContentType = MediaTypeHeaderValue.Parse(reference.ContentType);
                multipart.Add(bytes, "image[]", $"reference-{index}.{Extension(reference.ContentType)}");
            }
            using var edited = await PostContentAsync("/images/edits", multipart, ct);
            return ReadFirstImage(edited);
        }

        if (!Options.Model.StartsWith("gpt-image", StringComparison.OrdinalIgnoreCase)
            && !Options.Model.Equals("chatgpt-image-latest", StringComparison.OrdinalIgnoreCase))
        {
            body["response_format"] = "b64_json";
        }
        var json = body.ToJsonString();
        using var document = await PostAsync("/images/generations", json, ct);
        return ReadFirstImage(document);
    }

    private static string Extension(string type) => type.ToLowerInvariant() switch
    {
        "image/jpeg" => "jpg",
        "image/webp" => "webp",
        _ => "png",
    };
}
