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
using Procul.Api.Chat;
using Procul.Api.Chat.Models;
using Procul.Api.Chat.V1;
using Procul.Api.Infrastructure;
using Procul.Api.Security.V1;
using Procul.Api.Tests.Support;

namespace Procul.Api.Tests.Integration;

/// <summary>
/// Optimistic concurrency through the real endpoints: a mutating request that echoes a stale
/// <c>expectedRevision</c> is a <c>409 Conflict</c>, the current revision succeeds, and the
/// revision is bumped on every mutating save.
/// </summary>
public class ConcurrencyPipelineTests : IClassFixture<WebApplicationFactory<Program>>, IDisposable
{
    private const string Password = "correct horse battery staple";

    private readonly WebApplicationFactory<Program> _factory;
    private TempConfig? _config;

    public ConcurrencyPipelineTests(WebApplicationFactory<Program> factory) => _factory = factory;

    public void Dispose() => _config?.Dispose();

    private const string ConfigJson = """
        {
          "server": { "sessionLifetime": "30d" },
          "models": [
            {
              "slug": "model/one", "name": "One",
              "baseUrl": "https://openrouter.ai/api/v1", "apiKey": "x",
              "provider": "openrouter", "discoverCapabilities": false,
              "capabilities": ["text"], "default": true, "healthCheck": false
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
            ChatModelTestHelpers.Definition(slug: "model/one", capabilities: [ModelInputModality.Text])));
    }

    private static void ReplaceDbWithInMemory(IServiceCollection services)
    {
        var database = $"concurrency-{Guid.NewGuid()}";

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

    private static async Task<ConversationV1> CreateConversationAsync(HttpClient client)
    {
        using var response = await client.PostAsJsonAsync(
            "/v1/conversations", new CreateConversationRequestV1("hello", Model: "model/one"));
        await response.Content.ReadAsStringAsync(); // drains the SSE stream
        response.EnsureSuccessStatusCode();

        var list = await client.GetFromJsonAsync<GetConversationsResponseV1>("/v1/conversations");
        return list!.Conversations.Single();
    }

    [Fact]
    public async Task Rename_bumps_the_revision_and_a_stale_revision_conflicts()
    {
        using var client = await SignedInClientAsync(CreateFactory());
        var conversation = await CreateConversationAsync(client);
        var revision = conversation.Revision;
        Assert.True(revision >= 1);

        // Current revision: succeeds and bumps.
        using var renamed = await client.PatchAsJsonAsync(
            $"/v1/conversations/{conversation.Id}",
            new RenameConversationRequestV1("renamed", revision));
        renamed.EnsureSuccessStatusCode();
        var updated = (await renamed.Content.ReadFromJsonAsync<GetConversationResponseV1>())!.Conversation;
        Assert.Equal("renamed", updated.Title);
        Assert.Equal(revision + 1, updated.Revision);

        // Stale revision: conflict.
        using var stale = await client.PatchAsJsonAsync(
            $"/v1/conversations/{conversation.Id}",
            new RenameConversationRequestV1("again", revision));

        Assert.Equal(HttpStatusCode.Conflict, stale.StatusCode);
    }

    [Fact]
    public async Task Sending_with_a_stale_revision_is_a_409()
    {
        using var client = await SignedInClientAsync(CreateFactory());
        var conversation = await CreateConversationAsync(client);

        using var stale = await client.PostAsJsonAsync(
            $"/v1/conversations/{conversation.Id}/messages",
            new SendMessageRequestV1("hi", ExpectedRevision: conversation.Revision - 1));

        Assert.Equal(HttpStatusCode.Conflict, stale.StatusCode);

        // The current revision streams normally.
        using var ok = await client.PostAsJsonAsync(
            $"/v1/conversations/{conversation.Id}/messages",
            new SendMessageRequestV1("hi", ExpectedRevision: conversation.Revision));
        var body = await ok.Content.ReadAsStringAsync();
        Assert.Equal(HttpStatusCode.OK, ok.StatusCode);

        // The `done` event carries the post-turn revision so the client can echo it back.
        Assert.Contains("\"type\":\"done\"", body);
        Assert.Contains("\"revision\":", body);
    }

    [Fact]
    public async Task Setting_the_model_with_a_stale_revision_is_a_409()
    {
        using var client = await SignedInClientAsync(CreateFactory());
        var conversation = await CreateConversationAsync(client);

        using var stale = await client.PutAsJsonAsync(
            $"/v1/conversations/{conversation.Id}/model",
            new SetConversationModelRequestV1("model/one", conversation.Revision - 1));

        Assert.Equal(HttpStatusCode.Conflict, stale.StatusCode);

        using var ok = await client.PutAsJsonAsync(
            $"/v1/conversations/{conversation.Id}/model",
            new SetConversationModelRequestV1("model/one", conversation.Revision));

        ok.EnsureSuccessStatusCode();
    }

    [Fact]
    public async Task Editing_with_a_stale_revision_is_a_409()
    {
        using var client = await SignedInClientAsync(CreateFactory());
        var conversation = await CreateConversationAsync(client);

        var messages = await client.GetFromJsonAsync<GetConversationMessagesResponseV1>(
            $"/v1/conversations/{conversation.Id}/messages");
        var user = messages!.Messages.Single(m => m.MessageRole == MessageRole.User);

        using var stale = await client.PostAsJsonAsync(
            $"/v1/conversations/{conversation.Id}/messages/{user.Id}/edit",
            new EditMessageRequestV1("edited", null, conversation.Revision - 1));

        Assert.Equal(HttpStatusCode.Conflict, stale.StatusCode);

        using var ok = await client.PostAsJsonAsync(
            $"/v1/conversations/{conversation.Id}/messages/{user.Id}/edit",
            new EditMessageRequestV1("edited", null, conversation.Revision));
        await ok.Content.ReadAsStringAsync();
        Assert.Equal(HttpStatusCode.OK, ok.StatusCode);
    }
}
