using Procul.Api.Configuration;

namespace Procul.Api.Mcp;

/// <summary>
/// Settings for the MCP client support, derived from the <c>mcp</c> section of
/// <c>config.jsonc</c> at startup.
/// </summary>
public sealed class McpOptions
{
    /// <summary>The connect timeout used when <c>mcp.connectTimeout</c> is unset.</summary>
    public static readonly TimeSpan DefaultConnectTimeout = TimeSpan.FromSeconds(15);

    /// <summary>The health interval used when <c>mcp.healthInterval</c> is unset.</summary>
    public static readonly TimeSpan DefaultHealthInterval = TimeSpan.FromSeconds(60);

    /// <summary>Master switch: when false the configured servers are never connected.</summary>
    public required bool Enabled { get; init; }

    /// <summary>Per-server connect + tool-discovery budget.</summary>
    public required TimeSpan ConnectTimeout { get; init; }

    /// <summary>How often the background loop pings and reconnects.</summary>
    public required TimeSpan HealthInterval { get; init; }

    /// <summary>
    /// Builds the settings from the validated config. A malformed duration is fatal so a
    /// misconfigured deployment fails fast.
    /// </summary>
    /// <exception cref="InvalidOperationException">
    /// Thrown when <c>mcp.connectTimeout</c> or <c>mcp.healthInterval</c> is malformed.
    /// </exception>
    public static McpOptions FromConfig(ProculConfig config) => new()
    {
        Enabled = config.Mcp.Enabled,
        ConnectTimeout = DurationParser.Parse(
            config.Mcp.ConnectTimeout, DefaultConnectTimeout, "mcp.connectTimeout"),
        HealthInterval = DurationParser.Parse(
            config.Mcp.HealthInterval, DefaultHealthInterval, "mcp.healthInterval"),
    };
}
