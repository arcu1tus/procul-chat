using Microsoft.AspNetCore.Cors.Infrastructure;
using Microsoft.AspNetCore.Http;
using Microsoft.Extensions.DependencyInjection;
using Microsoft.Extensions.FileProviders;
using Microsoft.Extensions.Hosting;
using Procul.Api.Configuration;
using Procul.Api.Cors;

namespace Procul.Api.Tests.Cors;

public class CorsExtensionsTests
{
    [Fact]
    public async Task Production_allows_only_the_configured_origins()
    {
        var policy = await ResolvePolicyAsync("https://app.example.com", Environments.Production);

        Assert.False(policy.AllowAnyOrigin);
        Assert.Equal(new[] { "https://app.example.com" }, policy.Origins);
    }

    [Fact]
    public async Task Production_denies_cross_origin_requests_when_unconfigured()
    {
        var policy = await ResolvePolicyAsync(null, Environments.Production);

        Assert.False(policy.AllowAnyOrigin);
        Assert.Empty(policy.Origins);
    }

    [Fact]
    public async Task Development_allows_any_origin_when_unconfigured()
    {
        var policy = await ResolvePolicyAsync(null, Environments.Development);

        Assert.True(policy.AllowAnyOrigin);
    }

    [Fact]
    public async Task Configured_origins_take_precedence_over_the_development_wildcard()
    {
        var policy = await ResolvePolicyAsync("https://app.example.com", Environments.Development);

        Assert.False(policy.AllowAnyOrigin);
        Assert.Equal(new[] { "https://app.example.com" }, policy.Origins);
    }

    [Fact]
    public async Task Origins_are_trimmed_and_normalized()
    {
        var policy = await ResolvePolicyAsync(
            " https://app.example.com/ , https://other.example.com ", Environments.Production);

        Assert.Equal(
            new[] { "https://app.example.com", "https://other.example.com" },
            policy.Origins);
    }

    [Theory]
    [InlineData("*")]                                  // wildcard is never allowed
    [InlineData("app.example.com")]                    // not an absolute origin
    [InlineData("https://app.example.com/some/path")]  // origin must not carry a path
    public void Invalid_origin_configuration_fails_fast(string value)
        => Assert.Throws<InvalidOperationException>(() => Register(value, Environments.Production));

    private static void Register(string? origins, string environmentName)
    {
        var services = new ServiceCollection();
        services.AddLogging();
        services.AddProculCors(Config(origins), new StubHostEnvironment(environmentName));
    }

    private static async Task<CorsPolicy> ResolvePolicyAsync(string? origins, string environmentName)
    {
        var services = new ServiceCollection();
        services.AddLogging();
        services.AddProculCors(Config(origins), new StubHostEnvironment(environmentName));

        using var provider = services.BuildServiceProvider();
        var policyProvider = provider.GetRequiredService<ICorsPolicyProvider>();
        var policy = await policyProvider.GetPolicyAsync(new DefaultHttpContext(), CorsExtensions.PolicyName);

        Assert.NotNull(policy);
        return policy!;
    }

    private static ProculConfig Config(string? origins) => new()
    {
        Server = new ServerConfig
        {
            CorsAllowedOrigins = string.IsNullOrWhiteSpace(origins)
                ? []
                : [.. origins.Split(',', StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries)],
        },
    };

    private sealed class StubHostEnvironment(string environmentName) : IHostEnvironment
    {
        public string EnvironmentName { get; set; } = environmentName;
        public string ApplicationName { get; set; } = "Procul.Api.Tests";
        public string ContentRootPath { get; set; } = AppContext.BaseDirectory;
        public IFileProvider ContentRootFileProvider { get; set; } = new NullFileProvider();
    }
}
