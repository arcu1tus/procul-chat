using System.Net;
using System.Net.Http.Headers;
using System.Net.Http.Json;
using Microsoft.AspNetCore.Hosting;
using Microsoft.AspNetCore.Mvc.Testing;
using Microsoft.EntityFrameworkCore;
using Microsoft.Extensions.DependencyInjection;
using Procul.Api.Chat;
using Procul.Api.Chat.V1;
using Procul.Api.Infrastructure;
using Procul.Api.Security.V1;
using Procul.Api.Tests.Support;

namespace Procul.Api.Tests.Integration;

/// <summary>
/// Boots the real application with a temp config (models declared, health on but pointed at an
/// unreachable loopback port so probes fail fast without external network) and an in-memory EF
/// provider. Verifies the model list, per-conversation model selection, and the check endpoints.
/// </summary>
public class ModelPipelineTests : IClassFixture<WebApplicationFactory<Program>>, IDisposable
{
    private const string Password = "correct horse battery staple";

    private readonly WebApplicationFactory<Program> _factory;
    private TempConfig? _config;

    public ModelPipelineTests(WebApplicationFactory<Program> factory) => _factory = factory;

    private WebApplicationFactory<Program> CreateFactory()
    {
        _config = TempConfig.Write(ConfigJson);
        return _factory.WithWebHostBuilder(builder => builder
            .UseEnvironment("Production")
            .UseSetting("PROCUL_API_PASSWORD", Password)
            .UseSetting("PROCUL_CONFIG_PATH", _config.Path)
            .ConfigureServices(ReplaceDbWithInMemory));
    }

    public void Dispose() => _config?.Dispose();

    private const string ConfigJson = """
        {
          "server": { "sessionLifetime": "30d" },
          "models": [
            {
              "slug": "model/one", "name": "One", "description": "first",
              "baseUrl": "http://127.0.0.1:1/v1", "apiKey": "secret-one",
              "provider": "openai-compatible", "discoverCapabilities": false,
              "capabilities": ["text", "image"], "default": true, "healthCheck": true
            },
            {
              "slug": "model/two", "name": "Two",
              "baseUrl": "http://127.0.0.1:1/v1", "apiKey": "secret-two",
              "provider": "openai-compatible", "discoverCapabilities": false,
              "capabilities": ["text"], "healthCheck": false
            }
          ],
          "modelHealth": { "enabled": true, "timeout": "2s" },
          "mcp": { "enabled": false }
        }
        """;

    private static void ReplaceDbWithInMemory(IServiceCollection services)
    {
        var database = $"models-{Guid.NewGuid()}";

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
        var response = await client.PostAsJsonAsync(
            "/v1/auth/session", new CreateSessionRequestV1(Password));
        response.EnsureSuccessStatusCode();
        var session = await response.Content.ReadFromJsonAsync<CreateSessionResponseV1>();
        client.DefaultRequestHeaders.Authorization =
            new AuthenticationHeaderValue("Bearer", session!.Token);
        return client;
    }

    [Fact]
    public async Task The_models_endpoint_requires_a_token()
    {
        using var client = CreateFactory().CreateClient();

        using var response = await client.GetAsync("/v1/models");

        Assert.Equal(HttpStatusCode.Unauthorized, response.StatusCode);
    }

    [Fact]
    public async Task Lists_models_with_capabilities_and_health_without_secrets()
    {
        using var client = await SignedInClientAsync(CreateFactory());

        using var response = await client.GetAsync("/v1/models");

        Assert.Equal(HttpStatusCode.OK, response.StatusCode);
        var body = await response.Content.ReadAsStringAsync();

        Assert.Contains("\"defaultModel\":\"model/one\"", body);
        Assert.Contains("\"slug\":\"model/one\"", body);
        Assert.Contains("\"slug\":\"model/two\"", body);
        Assert.Contains("\"isDefault\":true", body);
        Assert.Contains("\"capabilities\":", body);
        Assert.Contains("\"image\"", body);
        Assert.Contains("\"health\":", body);

        // Secrets must never be returned.
        Assert.DoesNotContain("secret-one", body);
        Assert.DoesNotContain("secret-two", body);
        Assert.DoesNotContain("\"apiKey\"", body);
    }

    [Fact]
    public async Task Put_conversation_model_validates_and_sets()
    {
        var factory = CreateFactory();
        var conversationId = Guid.NewGuid();
        await SeedConversationAsync(factory, conversationId);
        using var client = await SignedInClientAsync(factory);

        using var unknown = await client.PutAsJsonAsync(
            $"/v1/conversations/{conversationId}/model", new SetConversationModelRequestV1("ghost"));
        Assert.Equal(HttpStatusCode.BadRequest, unknown.StatusCode);

        using var ok = await client.PutAsJsonAsync(
            $"/v1/conversations/{conversationId}/model", new SetConversationModelRequestV1("model/two"));
        Assert.Equal(HttpStatusCode.OK, ok.StatusCode);

        var body = await ok.Content.ReadFromJsonAsync<GetConversationResponseV1>();
        Assert.Equal("model/two", body!.Conversation.Model);
    }

    [Fact]
    public async Task Put_conversation_model_is_not_found_for_an_unknown_conversation()
    {
        using var client = await SignedInClientAsync(CreateFactory());

        using var response = await client.PutAsJsonAsync(
            $"/v1/conversations/{Guid.NewGuid()}/model", new SetConversationModelRequestV1("model/two"));

        Assert.Equal(HttpStatusCode.NotFound, response.StatusCode);
    }

    [Fact]
    public async Task The_check_endpoints_probe_and_report_not_found()
    {
        using var client = await SignedInClientAsync(CreateFactory());

        using var one = await client.PostAsync("/v1/models/model/one/check", null);
        using var all = await client.PostAsync("/v1/models/check", null);
        using var ghost = await client.PostAsync("/v1/models/ghost/check", null);

        Assert.Equal(HttpStatusCode.OK, one.StatusCode);
        Assert.Equal(HttpStatusCode.OK, all.StatusCode);
        Assert.Equal(HttpStatusCode.NotFound, ghost.StatusCode);
    }

    private static async Task SeedConversationAsync(WebApplicationFactory<Program> factory, Guid conversationId)
    {
        using var scope = factory.Services.CreateScope();
        var db = scope.ServiceProvider.GetRequiredService<ProculDbContext>();
        db.Conversations.Add(new Conversation { Id = conversationId, Title = "seed" });
        await db.SaveChangesAsync();
    }
}
