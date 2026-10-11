using System.Net;
using System.Net.Http.Headers;
using System.Net.Http.Json;
using Microsoft.AspNetCore.Hosting;
using Microsoft.AspNetCore.Mvc.Testing;
using Microsoft.EntityFrameworkCore;
using Microsoft.Extensions.AI;
using Microsoft.Extensions.DependencyInjection;
using Microsoft.Extensions.DependencyInjection.Extensions;
using Procul.Api.Attachments;
using Procul.Api.Attachments.V1;
using Procul.Api.Chat;
using Procul.Api.Chat.V1;
using Procul.Api.Infrastructure;
using Procul.Api.Security.V1;
using Procul.Api.Tests.Support;

namespace Procul.Api.Tests.Integration;

/// <summary>
/// Boots the real application (temp config + in-memory EF) and exercises the attachment surface
/// end to end: auth on every route, upload → metadata, download → bytes + headers, idempotent
/// delete, the size/content-type guards, and sending a message whose attachments reach the model
/// as content parts (captured through a fake client).
/// </summary>
public class AttachmentPipelineTests : IClassFixture<WebApplicationFactory<Program>>, IDisposable
{
    private const string Password = "correct horse battery staple";
    private const int MaxFileSize = 1024;

    private readonly WebApplicationFactory<Program> _factory;

    /// <summary>The messages the model received on the last captured turn.</summary>
    private readonly List<ChatMessage> _captured = [];

    private TempConfig? _config;

    public AttachmentPipelineTests(WebApplicationFactory<Program> factory) => _factory = factory;

    public void Dispose() => _config?.Dispose();

    private const string ConfigJson = """
        {
          "server": { "sessionLifetime": "30d" },
          "attachments": {
            "storage": "postgres",
            "maxFileSizeBytes": 1024,
            "allowedContentTypes": ["image/*", "text/*", "application/pdf"]
          },
          "models": [
            {
              "slug": "model/one", "name": "One",
              "baseUrl": "https://openrouter.ai/api/v1", "apiKey": "x",
              "provider": "openrouter", "discoverCapabilities": false,
              "capabilities": ["text", "image"], "default": true, "healthCheck": false
            }
          ],
          "modelHealth": { "enabled": false },
          "mcp": { "enabled": false }
        }
        """;

    private WebApplicationFactory<Program> CreateFactory()
    {
        _config = TempConfig.Write(ConfigJson);
        var client = new FakeChatClient(
            (_, _, _) => Task.FromResult(new ChatResponse(new ChatMessage(ChatRole.Assistant, "ok"))),
            (messages, _, ct) => CaptureAsync(messages, ct));

        return _factory.WithWebHostBuilder(builder => builder
            .UseEnvironment("Production")
            .UseSetting("PROCUL_API_PASSWORD", Password)
            .UseSetting("PROCUL_CONFIG_PATH", _config.Path)
            .ConfigureServices(services =>
            {
                ReplaceDbWithInMemory(services);
                ReplaceModels(services, client);
            }));
    }

    /// <summary>Captures the turn's messages, then streams a one-token reply.</summary>
    private async IAsyncEnumerable<ChatResponseUpdate> CaptureAsync(
        IEnumerable<ChatMessage> messages,
        [System.Runtime.CompilerServices.EnumeratorCancellation] CancellationToken ct)
    {
        _captured.Clear();
        _captured.AddRange(messages);
        yield return new ChatResponseUpdate(ChatRole.Assistant, "ok");
        await Task.CompletedTask;
    }

    private static void ReplaceModels(IServiceCollection services, IChatClient client)
    {
        services.RemoveAll<ChatModelRegistry>();
        services.AddSingleton(_ => ChatModelTestHelpers.Registry(
            (ChatModelTestHelpers.Definition(slug: "model/one", capabilities: [ModelInputModality.Text, ModelInputModality.Image]), client)));
    }

    private static void ReplaceDbWithInMemory(IServiceCollection services)
    {
        var database = $"attachments-{Guid.NewGuid()}";

        var toRemove = services
            .Where(descriptor =>
                descriptor.ServiceType == typeof(DbContextOptions<ProculDbContext>) ||
                descriptor.ServiceType == typeof(DbContextOptions) ||
                descriptor.ServiceType == typeof(ProculDbContext) ||
                IsGenericOf(descriptor.ServiceType, "Microsoft.EntityFrameworkCore.Infrastructure.IDbContextOptionsConfiguration`1"))
            .ToList();

        foreach (var descriptor in toRemove)
        {
            services.Remove(descriptor);
        }

        services.AddDbContext<ProculDbContext>(options => options.UseInMemoryDatabase(database));
    }

    private static bool IsGenericOf(Type type, string genericDefinitionFullName) =>
        type.IsGenericType &&
        type.GetGenericTypeDefinition().FullName == genericDefinitionFullName;

    private static async Task<HttpClient> SignedInClientAsync(WebApplicationFactory<Program> factory)
    {
        var client = factory.CreateClient();
        var response = await client.PostAsJsonAsync("/v1/auth/session", new CreateSessionRequestV1(Password));
        response.EnsureSuccessStatusCode();
        var session = await response.Content.ReadFromJsonAsync<CreateSessionResponseV1>();
        client.DefaultRequestHeaders.Authorization = new AuthenticationHeaderValue("Bearer", session!.Token);
        return client;
    }

    private static MultipartFormDataContent FileForm(byte[] bytes, string fileName, string contentType)
    {
        var content = new ByteArrayContent(bytes);
        content.Headers.ContentType = new MediaTypeHeaderValue(contentType);
        var form = new MultipartFormDataContent { { content, "file", fileName } };
        return form;
    }

    private static async Task<AttachmentV1> UploadAsync(HttpClient client, byte[] bytes, string fileName, string contentType)
    {
        using var form = FileForm(bytes, fileName, contentType);
        using var response = await client.PostAsync("/v1/attachments", form);
        response.EnsureSuccessStatusCode();
        return (await response.Content.ReadFromJsonAsync<AttachmentV1>())!;
    }

    [Fact]
    public async Task Every_attachment_route_requires_a_token()
    {
        using var client = CreateFactory().CreateClient();

        using var upload = await client.PostAsync("/v1/attachments", FileForm([1], "a.png", "image/png"));
        using var download = await client.GetAsync($"/v1/attachments/{Guid.NewGuid()}");
        using var delete = await client.DeleteAsync($"/v1/attachments/{Guid.NewGuid()}");

        Assert.Equal(HttpStatusCode.Unauthorized, upload.StatusCode);
        Assert.Equal(HttpStatusCode.Unauthorized, download.StatusCode);
        Assert.Equal(HttpStatusCode.Unauthorized, delete.StatusCode);
    }

    [Fact]
    public async Task Upload_download_and_delete_round_trip()
    {
        using var client = await SignedInClientAsync(CreateFactory());
        var bytes = new byte[] { 137, 80, 78, 71, 1, 2, 3, 4 };

        var upload = await UploadAsync(client, bytes, "photo.png", "image/png");
        Assert.Equal("photo.png", upload.FileName);
        Assert.Equal("image/png", upload.ContentType);
        Assert.Equal(bytes.Length, upload.SizeBytes);

        using var download = await client.GetAsync($"/v1/attachments/{upload.Id}");
        Assert.Equal(HttpStatusCode.OK, download.StatusCode);
        Assert.Equal("image/png", download.Content.Headers.ContentType?.MediaType);
        Assert.Contains("photo.png", download.Content.Headers.ContentDisposition?.ToString());
        Assert.Equal(bytes, await download.Content.ReadAsByteArrayAsync());

        using var deleted = await client.DeleteAsync($"/v1/attachments/{upload.Id}");
        Assert.Equal(HttpStatusCode.NoContent, deleted.StatusCode);

        using var gone = await client.GetAsync($"/v1/attachments/{upload.Id}");
        Assert.Equal(HttpStatusCode.NotFound, gone.StatusCode);

        // Deleting again is idempotent, and an unknown id is still 204.
        using var again = await client.DeleteAsync($"/v1/attachments/{upload.Id}");
        using var unknown = await client.DeleteAsync($"/v1/attachments/{Guid.NewGuid()}");
        Assert.Equal(HttpStatusCode.NoContent, again.StatusCode);
        Assert.Equal(HttpStatusCode.NoContent, unknown.StatusCode);
    }

    [Fact]
    public async Task An_oversized_upload_is_rejected_with_413()
    {
        using var client = await SignedInClientAsync(CreateFactory());

        using var form = FileForm(new byte[MaxFileSize + 1], "big.png", "image/png");
        using var response = await client.PostAsync("/v1/attachments", form);

        Assert.Equal(HttpStatusCode.RequestEntityTooLarge, response.StatusCode);
    }

    [Fact]
    public async Task A_disallowed_content_type_is_rejected_with_400()
    {
        using var client = await SignedInClientAsync(CreateFactory());

        using var form = FileForm([1, 2, 3], "archive.zip", "application/zip");
        using var response = await client.PostAsync("/v1/attachments", form);

        Assert.Equal(HttpStatusCode.BadRequest, response.StatusCode);
    }

    [Fact]
    public async Task Sending_an_image_reaches_the_model_as_a_content_part()
    {
        using var client = await SignedInClientAsync(CreateFactory());
        var upload = await UploadAsync(client, [1, 2, 3], "cat.png", "image/png");

        using var response = await client.PostAsJsonAsync(
            "/v1/conversations",
            new CreateConversationRequestV1("look", AttachmentIds: [upload.Id]));
        await response.Content.ReadAsStringAsync(); // drains the SSE, running the turn

        Assert.Equal(HttpStatusCode.OK, response.StatusCode);
        var user = _captured.Last(m => m.Role == ChatRole.User);
        Assert.Equal("look", user.Contents.OfType<TextContent>().First().Text);
        var image = Assert.IsType<DataContent>(user.Contents.OfType<DataContent>().Single());
        Assert.Equal("image/png", image.MediaType);
    }

    [Fact]
    public async Task Sending_a_type_the_model_cannot_read_is_rejected_with_400()
    {
        using var client = await SignedInClientAsync(CreateFactory());
        var upload = await UploadAsync(client, [1, 2, 3], "report.pdf", "application/pdf");

        using var response = await client.PostAsJsonAsync(
            "/v1/conversations",
            new CreateConversationRequestV1("read this", AttachmentIds: [upload.Id]));

        Assert.Equal(HttpStatusCode.BadRequest, response.StatusCode);
        Assert.Contains("report.pdf", await response.Content.ReadAsStringAsync());
    }

    [Fact]
    public async Task An_unknown_attachment_id_is_rejected_with_400()
    {
        using var client = await SignedInClientAsync(CreateFactory());

        using var response = await client.PostAsJsonAsync(
            "/v1/conversations",
            new CreateConversationRequestV1("hi", AttachmentIds: [Guid.NewGuid()]));

        Assert.Equal(HttpStatusCode.BadRequest, response.StatusCode);
    }
}
