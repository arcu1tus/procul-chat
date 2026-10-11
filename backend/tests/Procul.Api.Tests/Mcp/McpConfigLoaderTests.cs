using Microsoft.Extensions.Logging.Abstractions;
using Procul.Api.Mcp;

namespace Procul.Api.Tests.Mcp;

/// <summary>
/// Unit tests for validating the <c>mcpServers</c> section (already parsed and secret-resolved by
/// <c>ProculConfigLoader</c>): every fail-fast rule, and disabled-server skipping.
/// </summary>
public class McpConfigLoaderTests
{
    private static McpServerConfig Http(string url) => new() { Type = "http", Url = url };

    [Fact]
    public void Validates_http_and_sse_servers()
    {
        var servers = McpConfigLoader.Load(
            new Dictionary<string, McpServerConfig>
            {
                ["github"] = Http("https://api.githubcopilot.com/mcp/"),
                ["legacy"] = new() { Type = "sse", Url = "https://example.com/sse" },
            },
            NullLogger.Instance);

        Assert.Equal(2, servers.Count);
        Assert.Equal("github", servers[0].Name);
        Assert.Equal(McpTransportType.StreamableHttp, servers[0].Type);
        Assert.Equal("http", servers[0].TypeName);
        Assert.Equal("legacy", servers[1].Name);
        Assert.Equal(McpTransportType.Sse, servers[1].Type);
        Assert.Equal("sse", servers[1].TypeName);
    }

    [Fact]
    public void Preserves_headers()
    {
        var servers = McpConfigLoader.Load(
            new Dictionary<string, McpServerConfig>
            {
                ["github"] = new()
                {
                    Type = "http",
                    Url = "https://api.test/mcp",
                    Headers = new Dictionary<string, string> { ["Authorization"] = "Bearer s3cret" },
                },
            },
            NullLogger.Instance);

        var server = Assert.Single(servers);
        Assert.Equal("Bearer s3cret", server.Headers["Authorization"]);
    }

    [Theory]
    [InlineData("websocket", "unknown type")]
    [InlineData(null, "missing 'type'")]
    public void An_unknown_or_missing_type_throws(string? type, string expected)
    {
        var ex = Assert.Throws<InvalidOperationException>(() => McpConfigLoader.Load(
            new Dictionary<string, McpServerConfig>
            {
                ["s"] = new() { Type = type, Url = "https://x/mcp" },
            },
            NullLogger.Instance));

        Assert.Contains(expected, ex.Message);
    }

    [Fact]
    public void A_missing_url_throws()
    {
        var ex = Assert.Throws<InvalidOperationException>(() => McpConfigLoader.Load(
            new Dictionary<string, McpServerConfig> { ["s"] = new() { Type = "http" } },
            NullLogger.Instance));

        Assert.Contains("missing 'url'", ex.Message);
    }

    [Fact]
    public void A_non_absolute_url_throws()
    {
        var ex = Assert.Throws<InvalidOperationException>(() => McpConfigLoader.Load(
            new Dictionary<string, McpServerConfig> { ["s"] = Http("not-a-url") },
            NullLogger.Instance));

        Assert.Contains("invalid 'url'", ex.Message);
    }

    [Fact]
    public void A_blank_server_name_throws() =>
        Assert.Throws<InvalidOperationException>(() => McpConfigLoader.Load(
            new Dictionary<string, McpServerConfig> { ["   "] = Http("https://x/mcp") },
            NullLogger.Instance));

    [Fact]
    public void A_blank_header_name_throws() =>
        Assert.Throws<InvalidOperationException>(() => McpConfigLoader.Load(
            new Dictionary<string, McpServerConfig>
            {
                ["s"] = new()
                {
                    Type = "http",
                    Url = "https://x/mcp",
                    Headers = new Dictionary<string, string> { ["   "] = "value" },
                },
            },
            NullLogger.Instance));

    [Fact]
    public void Disabled_servers_are_skipped()
    {
        var servers = McpConfigLoader.Load(
            new Dictionary<string, McpServerConfig>
            {
                ["s"] = new() { Type = "http", Url = "https://x/mcp", Enabled = false },
            },
            NullLogger.Instance);

        Assert.Empty(servers);
    }
}
