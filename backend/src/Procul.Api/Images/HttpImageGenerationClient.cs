using System.Net.Http.Headers;
using System.Text;
using System.Text.Json;
using Procul.Api.Configuration;

namespace Procul.Api.Images;

/// <summary>
/// Shared plumbing for the HTTP image-generation clients: request timeouts, the bearer header,
/// URL composition, and decoding the common <c>{ "data": [ { "b64_json", "media_type" } ] }</c>
/// response shape.
/// </summary>
internal abstract class HttpImageGenerationClient(
    IHttpClientFactory httpClientFactory,
    ImageGenerationOptions options) : IImageGenerationClient
{
    /// <summary>The named <see cref="IHttpClientFactory"/> client used for image calls.</summary>
    public const string ClientName = "image-generation";

    protected ImageGenerationOptions Options { get; } = options;

    public abstract Task<GeneratedImage> GenerateAsync(ImageGenerationRequest request, CancellationToken ct);

    /// <summary>POSTs a JSON body and returns the parsed response, mapping failures to an exception.</summary>
    protected async Task<JsonDocument> PostAsync(string path, string json, CancellationToken ct)
    {
        using var timeout = CancellationTokenSource.CreateLinkedTokenSource(ct);
        timeout.CancelAfter(Options.Timeout);

        using var http = httpClientFactory.CreateClient(ClientName);
        using var message = new HttpRequestMessage(HttpMethod.Post, CombineUrl(Options.BaseUrl, path))
        {
            Content = new StringContent(json, Encoding.UTF8, "application/json"),
        };

        if (!string.IsNullOrWhiteSpace(Options.ApiKey))
        {
            message.Headers.Authorization = new AuthenticationHeaderValue("Bearer", Options.ApiKey);
        }

        HttpResponseMessage response;
        try
        {
            response = await http.SendAsync(message, HttpCompletionOption.ResponseContentRead, timeout.Token);
        }
        catch (OperationCanceledException) when (!ct.IsCancellationRequested)
        {
            throw new ImageGenerationException(
                $"The image provider did not respond within {Options.Timeout.TotalSeconds:0} seconds.");
        }
        catch (HttpRequestException ex)
        {
            throw new ImageGenerationException($"The image provider request failed: {ex.Message}");
        }

        using (response)
        {
            var body = await response.Content.ReadAsStringAsync(timeout.Token);
            if (!response.IsSuccessStatusCode)
            {
                throw new ImageGenerationException(
                    $"The image provider returned {(int)response.StatusCode}: {Truncate(body)}");
            }

            try
            {
                return JsonDocument.Parse(body);
            }
            catch (JsonException ex)
            {
                throw new ImageGenerationException($"The image provider returned invalid JSON: {ex.Message}");
            }
        }
    }

    /// <summary>
    /// Reads <c>data[0].b64_json</c> (and an optional <c>media_type</c>) from a provider response,
    /// inferring the media type from the magic bytes when the provider omits it.
    /// </summary>
    protected static GeneratedImage ReadFirstImage(JsonDocument document)
    {
        if (!document.RootElement.TryGetProperty("data", out var data)
            || data.ValueKind != JsonValueKind.Array
            || data.GetArrayLength() == 0
            || !data[0].TryGetProperty("b64_json", out var b64)
            || b64.ValueKind != JsonValueKind.String)
        {
            throw new ImageGenerationException("The image provider returned no image data.");
        }

        byte[] bytes;
        try
        {
            bytes = Convert.FromBase64String(b64.GetString() ?? string.Empty);
        }
        catch (FormatException)
        {
            throw new ImageGenerationException("The image provider returned malformed image data.");
        }

        if (bytes.Length == 0)
        {
            throw new ImageGenerationException("The image provider returned an empty image.");
        }

        var reported = data[0].TryGetProperty("media_type", out var media) && media.ValueKind == JsonValueKind.String
            ? media.GetString()
            : null;

        return new GeneratedImage(bytes, ImageTypeDetector.Detect(bytes, reported));
    }

    protected static string CombineUrl(string baseUrl, string path) =>
        baseUrl.TrimEnd('/') + path;

    private static string Truncate(string value) =>
        value.Length <= 500 ? value : value[..500];
}
