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
/// Boots the real application (temp config + in-memory EF) and exercises the destructive edit
/// endpoint end to end: auth, the 404/400 guards, the truncation + re-prompt, and the
/// attachment-already-attached check.
/// </summary>
public class EditPipelineTests : IClassFixture<WebApplicationFactory<Program>>, IDisposable
{
    private const string Password = "correct horse battery staple";

    private readonly WebApplicationFactory<Program> _factory;

    private TempConfig? _config;

    public EditPipelineTests(WebApplicationFactory<Program> factory) => _factory = factory;

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
        var database = $"edit-{Guid.NewGuid()}";

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

    private static async Task<AttachmentV1> UploadAsync(HttpClient client, byte[] bytes, string fileName, string contentType)
    {
        var content = new ByteArrayContent(bytes);
        content.Headers.ContentType = new MediaTypeHeaderValue(contentType);
        using var form = new MultipartFormDataContent { { content, "file", fileName } };
        using var response = await client.PostAsync("/v1/attachments", form);
        response.EnsureSuccessStatusCode();
        return (await response.Content.ReadFromJsonAsync<AttachmentV1>())!;
    }

    private static async Task<string> CreateConversationAsync(HttpClient client, string message, List<Guid>? attachmentIds = null)
    {
        using var response = await client.PostAsJsonAsync(
            "/v1/conversations",
            new CreateConversationRequestV1(message, null, attachmentIds));
        await response.Content.ReadAsStringAsync();
        response.EnsureSuccessStatusCode();

        var list = await client.GetFromJsonAsync<GetConversationsResponseV1>("/v1/conversations");
        return list!.Conversations[0].Id.ToString();
    }

    private static async Task SendAsync(HttpClient client, string conversationId, string text)
    {
        using var response = await client.PostAsJsonAsync(
            $"/v1/conversations/{conversationId}/messages",
            new SendMessageRequestV1(text));
        await response.Content.ReadAsStringAsync();
        response.EnsureSuccessStatusCode();
    }

    private static async Task<List<ConversationMessageV1>> MessagesAsync(HttpClient client, string conversationId)
    {
        var page = await client.GetFromJsonAsync<GetConversationMessagesResponseV1>(
            $"/v1/conversations/{conversationId}/messages?limit=100");
        return page!.Messages.OrderBy(m => m.CreatedAt).ThenBy(m => m.Id).ToList();
    }

    private static async Task<Guid> FirstIdAsync(HttpClient client, string conversationId, MessageRole role)
    {
        var messages = await MessagesAsync(client, conversationId);
        return messages.First(m => m.MessageRole == role).Id;
    }

    private static Task<HttpResponseMessage> PostEditAsync(
        HttpClient client, string conversationId, Guid messageId, EditMessageRequestV1 body) =>
        client.PostAsJsonAsync($"/v1/conversations/{conversationId}/messages/{messageId}/edit", body);

    [Fact]
    public async Task The_edit_route_requires_a_token()
    {
        using var client = CreateFactory().CreateClient();

        using var response = await PostEditAsync(client, Guid.NewGuid().ToString(), Guid.NewGuid(), new EditMessageRequestV1("x"));

        Assert.Equal(HttpStatusCode.Unauthorized, response.StatusCode);
    }

    [Fact]
    public async Task Editing_an_unknown_conversation_is_404()
    {
        using var client = await SignedInClientAsync(CreateFactory());

        using var response = await PostEditAsync(client, Guid.NewGuid().ToString(), Guid.NewGuid(), new EditMessageRequestV1("x"));

        Assert.Equal(HttpStatusCode.NotFound, response.StatusCode);
    }

    [Fact]
    public async Task Editing_an_unknown_message_is_404()
    {
        using var client = await SignedInClientAsync(CreateFactory());
        var conversationId = await CreateConversationAsync(client, "first");

        using var response = await PostEditAsync(client, conversationId, Guid.NewGuid(), new EditMessageRequestV1("x"));

        Assert.Equal(HttpStatusCode.NotFound, response.StatusCode);
    }

    [Fact]
    public async Task Editing_an_assistant_message_is_400()
    {
        using var client = await SignedInClientAsync(CreateFactory());
        var conversationId = await CreateConversationAsync(client, "first");
        var assistantId = await FirstIdAsync(client, conversationId, MessageRole.Assistant);

        using var response = await PostEditAsync(client, conversationId, assistantId, new EditMessageRequestV1("x"));

        Assert.Equal(HttpStatusCode.BadRequest, response.StatusCode);
    }

    [Fact]
    public async Task Editing_with_empty_text_is_400()
    {
        using var client = await SignedInClientAsync(CreateFactory());
        var conversationId = await CreateConversationAsync(client, "first");
        var userId = await FirstIdAsync(client, conversationId, MessageRole.User);

        using var response = await PostEditAsync(client, conversationId, userId, new EditMessageRequestV1("   "));

        Assert.Equal(HttpStatusCode.BadRequest, response.StatusCode);
    }

    [Fact]
    public async Task Editing_a_user_message_truncates_the_tail_end_to_end()
    {
        var factory = CreateFactory();
        using var client = await SignedInClientAsync(factory);
        var conversationId = await CreateConversationAsync(client, "first");
        await SendAsync(client, conversationId, "second");

        var userId = await FirstIdAsync(client, conversationId, MessageRole.User);

        using var response = await PostEditAsync(client, conversationId, userId, new EditMessageRequestV1("first edited"));
        await response.Content.ReadAsStringAsync();
        Assert.Equal(HttpStatusCode.OK, response.StatusCode);

        using var scope = factory.Services.CreateScope();
        var db = scope.ServiceProvider.GetRequiredService<ProculDbContext>();
        var id = Guid.Parse(conversationId);
        var messages = await db.ConversationMessages
            .Where(m => m.ConversationId == id)
            .OrderBy(m => m.CreatedAt)
            .ThenBy(m => m.Id)
            .ToListAsync();

        Assert.Equal(2, messages.Count);
        Assert.Equal("first edited", messages[0].Text);
        Assert.Equal(MessageRole.User, messages[0].MessageRole);
        Assert.Equal(MessageRole.Assistant, messages[1].MessageRole);
    }

    [Fact]
    public async Task Editing_with_an_attachment_from_another_message_is_400()
    {
        using var client = await SignedInClientAsync(CreateFactory());
        var upload = await UploadAsync(client, [1, 2, 3], "cat.png", "image/png");
        var conversationId = await CreateConversationAsync(client, "first", [upload.Id]);
        await SendAsync(client, conversationId, "second");

        var secondUserId = (await MessagesAsync(client, conversationId))
            .Last(m => m.MessageRole == MessageRole.User).Id;

        using var response = await PostEditAsync(
            client, conversationId, secondUserId, new EditMessageRequestV1("second edited", [upload.Id]));

        Assert.Equal(HttpStatusCode.BadRequest, response.StatusCode);
        Assert.Contains("already attached", await response.Content.ReadAsStringAsync());
    }

    [Fact]
    public async Task Sending_empty_text_is_400()
    {
        using var client = await SignedInClientAsync(CreateFactory());

        using var response = await client.PostAsJsonAsync(
            "/v1/conversations", new CreateConversationRequestV1("   "));

        Assert.Equal(HttpStatusCode.BadRequest, response.StatusCode);
    }
}
