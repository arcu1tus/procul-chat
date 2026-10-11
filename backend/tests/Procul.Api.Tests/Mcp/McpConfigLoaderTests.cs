using Microsoft.Extensions.Logging.Abstractions;
using Procul.Api.Mcp;
using Procul.Api.Tests.Support;

namespace Procul.Api.Tests.Mcp;

/// <summary>
/// Unit tests for the <c>config.jsonc</c> loader: JSONC tolerance, <c>${ENV}</c> interpolation,
/// and every fail-fast validation rule.
/// </summary>
public class McpConfigLoaderTests
{
    private static readonly Func<string, string?> NoEnv = _ => null;

    [Fact]
    public void Parses_jsonc_with_comments_and_trailing_commas()
    {
        using var config = TempConfig.Write("""
            {
              // Servers live under "mcpServers".
              "mcpServers": {
                "github": {
                  "type": "http",
                  "url": "https://api.githubcopilot.com/mcp/",
                },
                "legacy": { "type": "sse", "url": "https://example.com/sse" }
              }
            }
            """);

        var servers = McpConfigLoader.Load(FileOptions(config.Path), NullLogger.Instance, NoEnv);

        Assert.Equal(2, servers.Count);
        Assert.Equal("github", servers[0].Name);
        Assert.Equal(McpTransportType.StreamableHttp, servers[0].Type);
        Assert.Equal("http", servers[0].TypeName);
        Assert.Equal("legacy", servers[1].Name);
        Assert.Equal(McpTransportType.Sse, servers[1].Type);
        Assert.Equal("sse", servers[1].TypeName);
    }

    [Fact]
    public void Expands_environment_references_in_url_and_headers()
    {
        using var config = TempConfig.Write("""
            {
              "mcpServers": {
                "github": {
                  "type": "http",
                  "url": "https://${HOST}/mcp",
                  "headers": { "Authorization": "Bearer ${TOKEN}" }
                }
              }
            }
            """);

        var servers = McpConfigLoader.Load(
            FileOptions(config.Path),
            NullLogger.Instance,
            name => name switch { "HOST" => "api.test", "TOKEN" => "s3cret", _ => null });

        var server = Assert.Single(servers);
        Assert.Equal("https://api.test/mcp", server.Url);
        Assert.Equal("Bearer s3cret", server.Headers["Authorization"]);
    }

    [Fact]
    public void An_unresolved_environment_reference_throws_naming_the_variable()
    {
        using var config = TempConfig.Write("""
            { "mcpServers": { "github": { "type": "http", "url": "https://x/mcp",
              "headers": { "Authorization": "Bearer ${MISSING_TOKEN}" } } } }
            """);

        var ex = Assert.Throws<InvalidOperationException>(
            () => McpConfigLoader.Load(FileOptions(config.Path), NullLogger.Instance, NoEnv));

        Assert.Contains("MISSING_TOKEN", ex.Message);
    }

    [Theory]
    [InlineData("\"websocket\"", "unknown type")]
    [InlineData("null", "missing 'type'")]
    public void An_unknown_or_missing_type_throws(string typeJson, string expected)
    {
        using var config = TempConfig.Write($$"""
            { "mcpServers": { "s": { "type": {{typeJson}}, "url": "https://x/mcp" } } }
            """);

        var ex = Assert.Throws<InvalidOperationException>(
            () => McpConfigLoader.Load(FileOptions(config.Path), NullLogger.Instance, NoEnv));

        Assert.Contains(expected, ex.Message);
    }

    [Fact]
    public void A_missing_url_throws()
    {
        using var config = TempConfig.Write("""
            { "mcpServers": { "s": { "type": "http" } } }
            """);

        var ex = Assert.Throws<InvalidOperationException>(
            () => McpConfigLoader.Load(FileOptions(config.Path), NullLogger.Instance, NoEnv));

        Assert.Contains("missing 'url'", ex.Message);
    }

    [Fact]
    public void A_non_absolute_url_throws()
    {
        using var config = TempConfig.Write("""
            { "mcpServers": { "s": { "type": "http", "url": "not-a-url" } } }
            """);

        var ex = Assert.Throws<InvalidOperationException>(
            () => McpConfigLoader.Load(FileOptions(config.Path), NullLogger.Instance, NoEnv));

        Assert.Contains("invalid 'url'", ex.Message);
    }

    [Fact]
    public void A_blank_server_name_throws()
    {
        using var config = TempConfig.Write("""
            { "mcpServers": { "   ": { "type": "http", "url": "https://x/mcp" } } }
            """);

        Assert.Throws<InvalidOperationException>(
            () => McpConfigLoader.Load(FileOptions(config.Path), NullLogger.Instance, NoEnv));
    }

    [Fact]
    public void Disabled_servers_are_skipped()
    {
        using var config = TempConfig.Write("""
            { "mcpServers": { "s": { "type": "http", "url": "https://x/mcp", "enabled": false } } }
            """);

        var servers = McpConfigLoader.Load(FileOptions(config.Path), NullLogger.Instance, NoEnv);

        Assert.Empty(servers);
    }

    [Fact]
    public void A_missing_default_file_disables_mcp()
    {
        var options = FileOptions($"procul-missing-{Guid.NewGuid():N}.jsonc", explicitPath: false);

        var servers = McpConfigLoader.Load(options, NullLogger.Instance, NoEnv);

        Assert.Empty(servers);
    }

    [Fact]
    public void A_missing_explicit_file_throws()
    {
        var options = FileOptions($"procul-missing-{Guid.NewGuid():N}.jsonc", explicitPath: true);

        var ex = Assert.Throws<InvalidOperationException>(
            () => McpConfigLoader.Load(options, NullLogger.Instance, NoEnv));

        Assert.Contains("does not exist", ex.Message);
    }

    [Fact]
    public void Malformed_json_throws()
    {
        using var config = TempConfig.Write("{ this is not json");

        var ex = Assert.Throws<InvalidOperationException>(
            () => McpConfigLoader.Load(FileOptions(config.Path), NullLogger.Instance, NoEnv));

        Assert.Contains("not valid JSON", ex.Message);
    }

    private static McpOptions FileOptions(string path, bool explicitPath = true) => new()
    {
        Enabled = true,
        ConfigPath = path,
        ConfigPathExplicit = explicitPath,
        ConnectTimeout = McpOptions.DefaultConnectTimeout,
        HealthInterval = McpOptions.DefaultHealthInterval,
    };
}
