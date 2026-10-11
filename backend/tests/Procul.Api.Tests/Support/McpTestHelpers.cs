using Microsoft.Extensions.Logging.Abstractions;
using Procul.Api.Configuration;
using Procul.Api.Mcp;

namespace Procul.Api.Tests.Support;

/// <summary>
/// Helpers for constructing the MCP machinery in tests without a config file or network.
/// </summary>
internal static class McpTestHelpers
{
    /// <summary>Builds a minimal <see cref="ProculConfig"/> with the given servers and MCP settings.</summary>
    public static ProculConfig Config(
        Dictionary<string, McpServerConfig>? servers = null,
        bool enabled = true,
        string? connectTimeout = null,
        string? healthInterval = null) => new()
    {
        McpServers = servers ?? new(),
        Mcp = new McpSettingsConfig
        {
            Enabled = enabled,
            ConnectTimeout = connectTimeout,
            HealthInterval = healthInterval,
        },
    };

    /// <summary>Builds <see cref="McpOptions"/> from a small synthetic config.</summary>
    public static McpOptions Options(
        bool enabled = true,
        string? connectTimeout = null,
        string? healthInterval = null) =>
        McpOptions.FromConfig(Config(enabled: enabled, connectTimeout: connectTimeout, healthInterval: healthInterval));

    /// <summary>An MCP manager over the given config.</summary>
    public static McpClientManager Manager(ProculConfig config, McpOptions? options = null) => new(
        options ?? Options(),
        config,
        NullLoggerFactory.Instance,
        NullLogger<McpClientManager>.Instance);

    /// <summary>An MCP manager whose master switch is off, so it publishes no tools.</summary>
    public static McpClientManager DisabledManager() => Manager(Config(), Options(enabled: false));

    /// <summary>An MCP manager with MCP enabled but no servers configured.</summary>
    public static McpClientManager EmptyManager() => Manager(Config());
}
