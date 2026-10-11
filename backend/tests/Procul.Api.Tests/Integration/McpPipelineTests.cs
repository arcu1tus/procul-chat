using System.Net;
using System.Net.Http.Headers;
using System.Net.Http.Json;
using Microsoft.AspNetCore.Hosting;
using Microsoft.AspNetCore.Mvc.Testing;
using Procul.Api.Security.V1;
using Procul.Api.Tests.Support;

namespace Procul.Api.Tests.Integration;

/// <summary>
/// Boots the real application with an MCP config that points at an unreachable server and
/// verifies the status endpoint: it is authenticated, reports the server as offline, and never
/// leaks headers or tokens. No database is needed — the endpoint reads the manager's state only.
/// </summary>
public class McpPipelineTests : IClassFixture<WebApplicationFactory<Program>>
{
    private const string Password = "correct horse battery staple";
    private const string SecretToken = "super-secret-mcp-token";

    private readonly WebApplicationFactory<Program> _factory;

    public McpPipelineTests(WebApplicationFactory<Program> factory) => _factory = factory;

    private WebApplicationFactory<Program> CreateFactory(string configPath) =>
        _factory.WithWebHostBuilder(builder => builder
            .UseEnvironment("Production")
            .UseSetting("PROCUL_API_PASSWORD", Password)
            .UseSetting("PROCUL_CONFIG_PATH", configPath));

    private static TempConfig Config() => TestConfig.Write(mcpServers: $$"""
        {
          "github": {
            "type": "http",
            "url": "http://127.0.0.1:1/mcp",
            "headers": { "Authorization": "Bearer {{SecretToken}}" }
          }
        }
        """);

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
    public async Task The_mcp_status_endpoint_requires_a_token()
    {
        using var config = Config();
        using var client = CreateFactory(config.Path).CreateClient();

        using var response = await client.GetAsync("/v1/mcp/servers");

        Assert.Equal(HttpStatusCode.Unauthorized, response.StatusCode);
    }

    [Fact]
    public async Task The_mcp_status_endpoint_reports_servers_without_secrets()
    {
        using var config = Config();
        using var client = await SignedInClientAsync(CreateFactory(config.Path));

        using var response = await client.GetAsync("/v1/mcp/servers");

        Assert.Equal(HttpStatusCode.OK, response.StatusCode);
        var body = await response.Content.ReadAsStringAsync();

        Assert.Contains("\"name\":\"github\"", body);
        Assert.Contains("\"connected\":false", body);
        // Secrets and headers must never be returned.
        Assert.DoesNotContain(SecretToken, body);
        Assert.DoesNotContain("Authorization", body, StringComparison.OrdinalIgnoreCase);
        Assert.DoesNotContain("\"headers\"", body);
    }

    [Fact]
    public async Task Reconnecting_an_unknown_server_is_not_found()
    {
        using var config = Config();
        using var client = await SignedInClientAsync(CreateFactory(config.Path));

        using var response = await client.PostAsync("/v1/mcp/servers/nope/reconnect", null);

        Assert.Equal(HttpStatusCode.NotFound, response.StatusCode);
    }
}
