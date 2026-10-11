using Microsoft.Extensions.Configuration;
using Microsoft.Extensions.Logging.Abstractions;
using Procul.Api.Mcp;

namespace Procul.Api.Tests.Support;

/// <summary>
/// Helpers for constructing the MCP machinery in tests without a config file or network.
/// </summary>
internal static class McpTestHelpers
{
    /// <summary>Builds <see cref="McpOptions"/> from a small in-memory configuration.</summary>
    public static McpOptions Options(params (string Key, string? Value)[] settings) =>
        McpOptions.FromConfiguration(BuildConfiguration(settings));

    /// <summary>An MCP manager whose master switch is off, so it publishes no tools.</summary>
    public static McpClientManager DisabledManager() => new(
        Options((McpOptions.EnabledSetting, "false")),
        NullLoggerFactory.Instance,
        NullLogger<McpClientManager>.Instance);

    /// <summary>An MCP manager with MCP enabled but no servers configured.</summary>
    public static McpClientManager EmptyManager() => new(
        Options(),
        NullLoggerFactory.Instance,
        NullLogger<McpClientManager>.Instance);

    private static IConfiguration BuildConfiguration((string Key, string? Value)[] settings)
    {
        var data = new Dictionary<string, string?>();
        foreach (var (key, value) in settings)
        {
            data[key] = value;
        }

        return new ConfigurationBuilder().AddInMemoryCollection(data).Build();
    }
}
