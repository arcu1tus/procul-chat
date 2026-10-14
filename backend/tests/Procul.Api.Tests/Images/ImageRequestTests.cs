using System.Net;
using System.Text;
using System.Text.Json;
using Procul.Api.Configuration;
using Procul.Api.Images;
using Xunit;
using ImageRequest = Procul.Api.Images.ImageGenerationRequest;

namespace Procul.Api.Tests.Images;

public class ImageRequestTests
{
    [Theory]
    [InlineData("openrouter")]
    [InlineData("openai-compatible")]
    public async Task References_use_the_documented_endpoint_and_preserve_order(string provider)
    {
        var handler = new CaptureHandler();
        var factory = new ClientFactory(handler);
        var options = Procul.Api.Configuration.ImageGenerationOptions.FromConfig(new ProculConfig
        {
            ImageGeneration = new() { Enabled = true, Provider = provider, Model = "gpt-image-1", BaseUrl = "https://example.com/v1", ApiKey = "test" },
        });
        IImageGenerationClient client = provider == "openrouter"
            ? new OpenRouterImageClient(factory, options) : new OpenAiCompatibleImageClient(factory, options);
        await client.GenerateAsync(new ImageRequest("edit", [new([1, 2], "image/png"), new([3, 4], "image/jpeg")], "1024x1024", null), CancellationToken.None);
        if (provider == "openrouter")
        {
            Assert.EndsWith("/images", handler.Url);
            using var json = JsonDocument.Parse(handler.Body!);
            var refs = json.RootElement.GetProperty("input_references");
            Assert.Equal("image_url", refs[0].GetProperty("type").GetString());
            Assert.EndsWith("AQI=", refs[0].GetProperty("image_url").GetProperty("url").GetString());
            Assert.EndsWith("AwQ=", refs[1].GetProperty("image_url").GetProperty("url").GetString());
        }
        else
        {
            Assert.EndsWith("/images/edits", handler.Url);
            Assert.StartsWith("multipart/form-data", handler.Type);
            Assert.Equal(2, handler.Parts.Count(p => p.Name == "image[]"));
            Assert.Equal(new byte[] { 1, 2 }, handler.Parts.First(p => p.Name == "image[]").Data);
            Assert.DoesNotContain(handler.Parts, p => p.Name == "response_format");
        }
    }

    private sealed class ClientFactory(CaptureHandler handler) : IHttpClientFactory
    {
        public HttpClient CreateClient(string name) => new(handler, disposeHandler: false);
    }
    private sealed class CaptureHandler : HttpMessageHandler
    {
        public string? Url;
        public string? Type;
        public string? Body;
        public List<(string? Name, byte[] Data)> Parts = [];
        protected override async Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken ct)
        {
            Url = request.RequestUri!.AbsoluteUri;
            Type = request.Content!.Headers.ContentType!.ToString();
            if (request.Content is MultipartFormDataContent multipart)
                foreach (var part in multipart) Parts.Add((part.Headers.ContentDisposition!.Name!.Trim('"'), await part.ReadAsByteArrayAsync(ct)));
            else Body = await request.Content.ReadAsStringAsync(ct);
            return new(HttpStatusCode.OK) { Content = new StringContent("{\"data\":[{\"b64_json\":\"iVBORw0KGgo=\",\"media_type\":\"image/png\"}]}", Encoding.UTF8, "application/json") };
        }
    }
}
