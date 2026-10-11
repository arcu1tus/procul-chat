using System.Net;
using Microsoft.AspNetCore.Hosting;
using Microsoft.AspNetCore.Mvc.Testing;

namespace Procul.Api.Tests.Integration;

/// <summary>
/// Boots the real application (no database or network calls are made by a CORS preflight) and
/// verifies the production CORS contract end-to-end: only configured origins are approved, and
/// there is no wildcard outside development.
/// </summary>
public class CorsPipelineTests : IClassFixture<WebApplicationFactory<Program>>
{
    private readonly WebApplicationFactory<Program> _factory;

    public CorsPipelineTests(WebApplicationFactory<Program> factory) => _factory = factory;

    [Fact]
    public async Task Preflight_from_an_allowed_origin_is_approved_in_production()
    {
        using var factory = _factory.WithWebHostBuilder(builder => builder
            .UseEnvironment("Production")
            .UseSetting("CORS_ALLOWED_ORIGINS", "https://app.example.com")
            .UseSetting("OPENROUTER_API_KEY", "test")
            .UseSetting("OPENROUTER_MODEL_SLUG", "test/model")
            .UseSetting("PROCUL_API_PASSWORD", "test-password"));
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
        using var factory = _factory.WithWebHostBuilder(builder => builder
            .UseEnvironment("Production")
            .UseSetting("CORS_ALLOWED_ORIGINS", "https://app.example.com")
            .UseSetting("OPENROUTER_API_KEY", "test")
            .UseSetting("OPENROUTER_MODEL_SLUG", "test/model")
            .UseSetting("PROCUL_API_PASSWORD", "test-password"));
        using var client = factory.CreateClient();

        using var response = await PreflightAsync(client, "https://evil.example.com");

        Assert.Equal(HttpStatusCode.NoContent, response.StatusCode);
        Assert.False(response.Headers.Contains("Access-Control-Allow-Origin"));
    }

    [Fact]
    public async Task Preflight_is_approved_for_any_origin_in_development()
    {
        using var factory = _factory.WithWebHostBuilder(builder => builder
            .UseEnvironment("Development")
            .UseSetting("OPENROUTER_API_KEY", "test")
            .UseSetting("OPENROUTER_MODEL_SLUG", "test/model")
            .UseSetting("PROCUL_API_PASSWORD", "test-password"));
        using var client = factory.CreateClient();

        using var response = await PreflightAsync(client, "http://localhost:12345");

        Assert.Equal(HttpStatusCode.NoContent, response.StatusCode);
        Assert.Equal("*", response.Headers.GetValues("Access-Control-Allow-Origin").Single());
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
