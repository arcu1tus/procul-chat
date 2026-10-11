using System.Net;
using System.Net.Http.Headers;
using System.Net.Http.Json;
using System.Runtime.CompilerServices;
using Microsoft.AspNetCore.Hosting;
using Microsoft.AspNetCore.Mvc.Testing;
using Microsoft.EntityFrameworkCore;
using Microsoft.Extensions.AI;
using Microsoft.Extensions.DependencyInjection;
using Microsoft.Extensions.DependencyInjection.Extensions;
using Procul.Api.Attachments;
using Procul.Api.Attachments.V1;
using Procul.Api.Chat;
using Procul.Api.Chat.Models;
using Procul.Api.Chat.V1;
using Procul.Api.Infrastructure;
using Procul.Api.Security.V1;
using Procul.Api.Tests.Support;

namespace Procul.Api.Tests.Integration;

/// <summary>
/// Boots the real application with an in-memory EF provider <em>and</em> a swappable
/// <see cref="FakeAttachmentStore"/>, so the byte-level cleanup can be asserted directly: deleting
/// a conversation must remove its attachments' bytes, not just their metadata rows.
/// </summary>
public class AttachmentCleanupPipelineTests : IClassFixture<WebApplicationFactory<Program>>, IDisposable
{
    private const string Password = "correct horse battery staple";

    private readonly WebApplicationFactory<Program> _factory;
    private readonly FakeAttachmentStore _store = new();

    private TempConfig? _config;

    public AttachmentCleanupPipelineTests(WebApplicationFactory<Program> factory) => _factory = factory;

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
            (_, _, _) => StreamAsync());

        return _factory.WithWebHostBuilder(builder => builder
            .UseEnvironment("Production")
            .UseSetting("PROCUL_API_PASSWORD", Password)
            .UseSetting("PROCUL_CONFIG_PATH", _config.Path)
            .ConfigureServices(services =>
            {
                ReplaceDbWithInMemory(services);
                ReplaceModels(services, client);
                services.RemoveAll<IAttachmentStore>();
                services.AddSingleton<IAttachmentStore>(_store);
            }));
    }

    private static async IAsyncEnumerable<ChatResponseUpdate> StreamAsync(
        [EnumeratorCancellation] CancellationToken ct = default)
    {
        yield return new ChatResponseUpdate(ChatRole.Assistant, "ok");
        await Task.CompletedTask;
    }

    private static void ReplaceModels(IServiceCollection services, IChatClient client)
    {
        services.RemoveAll<ChatModelRegistry>();
        services.AddSingleton(_ => ChatModelTestHelpers.Registry(
            client,
            ChatModelTestHelpers.Definition(
                slug: "model/one",
                capabilities: [ModelInputModality.Text, ModelInputModality.Image])));
    }

    private static void ReplaceDbWithInMemory(IServiceCollection services)
    {
        var database = $"cleanup-{Guid.NewGuid()}";

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

    [Fact]
    public async Task Deleting_a_conversation_removes_its_attachment_bytes()
    {
        using var client = await SignedInClientAsync(CreateFactory());

        var content = new ByteArrayContent([1, 2, 3]);
        content.Headers.ContentType = new MediaTypeHeaderValue("image/png");
        using var form = new MultipartFormDataContent { { content, "file", "cat.png" } };
        using var uploadResponse = await client.PostAsync("/v1/attachments", form);
        uploadResponse.EnsureSuccessStatusCode();
        var upload = (await uploadResponse.Content.ReadFromJsonAsync<AttachmentV1>())!;

        // The bytes are in the store once uploaded, and stay there when attached.
        Assert.Equal(1, _store.Count);

        using var create = await client.PostAsJsonAsync(
            "/v1/conversations",
            new CreateConversationRequestV1("look", null, [upload.Id]));
        await create.Content.ReadAsStringAsync();
        create.EnsureSuccessStatusCode();
        Assert.Equal(1, _store.Count);

        var conversation = (await client.GetFromJsonAsync<GetConversationsResponseV1>("/v1/conversations"))!
            .Conversations[0];

        using var deleted = await client.DeleteAsync($"/v1/conversations/{conversation.Id}");
        Assert.Equal(HttpStatusCode.NoContent, deleted.StatusCode);

        // The fix: the store is emptied, not just the metadata rows.
        Assert.Equal(0, _store.Count);
    }
}
