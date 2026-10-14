using System.Net;
using System.Net.Http.Headers;
using System.Net.Http.Json;
using Microsoft.AspNetCore.Hosting;
using Microsoft.AspNetCore.Mvc.Testing;
using Procul.Api.Security.V1;
using Procul.Api.Tests.Support;

namespace Procul.Api.Tests.Integration;

/// <summary>
/// Boots the real application and verifies the password-gated API end-to-end: the health probe
/// stays public, the chat API requires a valid session token, and the token exchange works. No
/// database is needed — authorization rejects unauthenticated requests before any handler runs,
/// and the authenticated probe endpoint never touches the database.
/// </summary>
public class AuthPipelineTests : IClassFixture<WebApplicationFactory<Program>>, IDisposable
{
    private const string Password = "correct horse battery staple";

    private readonly WebApplicationFactory<Program> _factory;
    private TempConfig? _config;

    public AuthPipelineTests(WebApplicationFactory<Program> factory) => _factory = factory;

    private WebApplicationFactory<Program> CreateFactory(string password = Password)
    {
        _config = TestConfig.Write();
        return _factory.WithWebHostBuilder(builder => builder
            .UseEnvironment("Production")
            .UseSetting("PROCUL_API_PASSWORD", password)
            .UseSetting("PROCUL_CONFIG_PATH", _config.Path));
    }

    public void Dispose() => _config?.Dispose();

    [Fact]
    public async Task Restart_with_a_new_password_rejects_old_sessions_and_accepts_new_ones()
    {
        using var oldFactory = CreateFactory();
        using var oldClient = oldFactory.CreateClient();
        using var issued = await oldClient.PostAsJsonAsync("/v1/auth/session", new CreateSessionRequestV1(Password));
        var oldSession = await issued.Content.ReadFromJsonAsync<CreateSessionResponseV1>();
        using var newFactory = CreateFactory("new shared password");
        using var newClient = newFactory.CreateClient();
        newClient.DefaultRequestHeaders.Authorization = new AuthenticationHeaderValue("Bearer", oldSession!.Token);
        using var rejected = await newClient.GetAsync("/v1/auth/session");
        Assert.Equal(HttpStatusCode.Unauthorized, rejected.StatusCode);
        using var login = await newClient.PostAsJsonAsync("/v1/auth/session", new CreateSessionRequestV1("new shared password"));
        login.EnsureSuccessStatusCode();
        var newSession = await login.Content.ReadFromJsonAsync<CreateSessionResponseV1>();
        newClient.DefaultRequestHeaders.Authorization = new AuthenticationHeaderValue("Bearer", newSession!.Token);
        using var accepted = await newClient.GetAsync("/v1/auth/session");
        Assert.Equal(HttpStatusCode.NoContent, accepted.StatusCode);
    }

    [Fact]
    public async Task Health_is_public()
    {
        using var client = CreateFactory().CreateClient();

        using var response = await client.GetAsync("/health");

        Assert.Equal(HttpStatusCode.OK, response.StatusCode);
    }

    [Fact]
    public async Task The_chat_api_rejects_a_request_without_a_token()
    {
        using var client = CreateFactory().CreateClient();

        using var response = await client.GetAsync("/v1/conversations");

        Assert.Equal(HttpStatusCode.Unauthorized, response.StatusCode);
    }

    [Fact]
    public async Task The_chat_api_rejects_an_invalid_token()
    {
        using var client = CreateFactory().CreateClient();
        client.DefaultRequestHeaders.Authorization = new AuthenticationHeaderValue("Bearer", "not-a-jwt");

        using var response = await client.GetAsync("/v1/conversations");

        Assert.Equal(HttpStatusCode.Unauthorized, response.StatusCode);
    }

    [Fact]
    public async Task The_wrong_password_is_rejected()
    {
        using var client = CreateFactory().CreateClient();

        using var response = await client.PostAsJsonAsync(
            "/v1/auth/session",
            new CreateSessionRequestV1("wrong password"));

        Assert.Equal(HttpStatusCode.Unauthorized, response.StatusCode);
    }

    [Fact]
    public async Task The_correct_password_returns_a_usable_token()
    {
        using var client = CreateFactory().CreateClient();

        using var response = await client.PostAsJsonAsync(
            "/v1/auth/session",
            new CreateSessionRequestV1(Password));

        Assert.Equal(HttpStatusCode.OK, response.StatusCode);

        var session = await response.Content.ReadFromJsonAsync<CreateSessionResponseV1>();
        Assert.NotNull(session);
        Assert.False(string.IsNullOrWhiteSpace(session!.Token));
        Assert.True(session.ExpiresAt > DateTimeOffset.UtcNow);

        // The token authenticates a request that does not need the database.
        client.DefaultRequestHeaders.Authorization =
            new AuthenticationHeaderValue("Bearer", session.Token);
        using var probe = await client.GetAsync("/v1/auth/session");
        Assert.Equal(HttpStatusCode.NoContent, probe.StatusCode);
    }

    [Fact]
    public async Task The_session_probe_requires_a_token()
    {
        using var client = CreateFactory().CreateClient();

        using var response = await client.GetAsync("/v1/auth/session");

        Assert.Equal(HttpStatusCode.Unauthorized, response.StatusCode);
    }
}
