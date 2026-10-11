using System.Net;
using Microsoft.AspNetCore.Hosting;
using Microsoft.AspNetCore.Mvc.Testing;
using Procul.Api.Tests.Support;

namespace Procul.Api.Tests.Integration;

/// <summary>
/// Boots the real application (no database or network calls are made by a CORS preflight) and
/// verifies the production CORS contract end-to-end: only configured origins are approved, and
/// there is no wildcard outside development.
/// </summary>
public class CorsPipelineTests : IClassFixture<WebApplicationFactory<Program>>, IDisposable
{
    private readonly WebApplicationFactory<Program> _factory;
    private TempConfig? _config;

    public CorsPipelineTests(WebApplicationFactory<Program> factory) => _factory = factory;

    private WebApplicationFactory<Program> CreateFactory(string environment, string? origins)
    {
        _config = TestConfig.Write(corsOrigins: origins);
        return _factory.WithWebHostBuilder(builder => builder
            .UseEnvironment(environment)
            .UseSetting("PROCUL_API_PASSWORD", "test-password")
            .UseSetting("PROCUL_CONFIG_PATH", _config.Path));
    }

    public void Dispose() => _config?.Dispose();

    [Fact]
    public async Task Preflight_from_an_allowed_origin_is_approved_in_production()
    {
        using var factory = CreateFactory("Production", "https://app.example.com");
        using var client = factory.CreateClient();

        using var response = await PreflightAsync(client, "https://app.example.com");

        Assert.Equal(HttpStatusCode.NoContent, response.StatusCode);
        Assert.Equal(
            "https://app.example.com",
            response.Headers.GetValues("Access-Control-Allow-Origin").Single());
    }

    [Fact]
    public async Task Preflight_from_a_disallowed_origin_is_not_approved_in_production()
    {
        using var factory = CreateFactory("Production", "https://app.example.com");
        using var client = factory.CreateClient();

        using var response = await PreflightAsync(client, "https://evil.example.com");

        Assert.Equal(HttpStatusCode.NoContent, response.StatusCode);
        Assert.False(response.Headers.Contains("Access-Control-Allow-Origin"));
    }

    [Fact]
    public async Task Preflight_is_approved_for_any_origin_in_development()
    {
        using var factory = CreateFactory("Development", origins: null);
        using var client = factory.CreateClient();

        using var response = await PreflightAsync(client, "http://localhost:12345");

        Assert.Equal(HttpStatusCode.NoContent, response.StatusCode);
        Assert.Equal("*", response.Headers.GetValues("Access-Control-Allow-Origin").Single());
    }

    [Fact]
    public async Task A_cross_origin_response_exposes_Content_Disposition()
    {
        using var factory = CreateFactory("Production", "https://app.example.com");
        using var client = factory.CreateClient();

        using var request = new HttpRequestMessage(HttpMethod.Get, "/health");
        request.Headers.Add("Origin", "https://app.example.com");
        using var response = await client.SendAsync(request);

        Assert.Equal(HttpStatusCode.OK, response.StatusCode);
        Assert.Contains(
            "Content-Disposition",
            response.Headers.GetValues("Access-Control-Expose-Headers").Single());
    }

    private static Task<HttpResponseMessage> PreflightAsync(HttpClient client, string origin)
    {
        var request = new HttpRequestMessage(HttpMethod.Options, "/v1/conversations");
        request.Headers.Add("Origin", origin);
        request.Headers.Add("Access-Control-Request-Method", "POST");
        request.Headers.Add("Access-Control-Request-Headers", "content-type");
        return client.SendAsync(request);
    }
}
