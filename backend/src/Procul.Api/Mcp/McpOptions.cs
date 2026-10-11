using Procul.Api.Configuration;

namespace Procul.Api.Mcp;

/// <summary>
/// Settings for the MCP client support, read once at startup from configuration
/// (environment variables, loaded from <c>.env</c> in development).
/// </summary>
public sealed class McpOptions
{
    /// <summary>Configuration key holding the config-file path.</summary>
    public const string ConfigPathSetting = "PROCUL_CONFIG_PATH";

    /// <summary>Configuration key holding the master switch.</summary>
    public const string EnabledSetting = "MCP_ENABLED";

    /// <summary>Configuration key holding the per-server connect/discover timeout.</summary>
    public const string ConnectTimeoutSetting = "MCP_CONNECT_TIMEOUT";

    /// <summary>Configuration key holding the background health/reconnect cadence.</summary>
    public const string HealthIntervalSetting = "MCP_HEALTH_INTERVAL";

    /// <summary>The config file looked up next to the app when no path is set.</summary>
    public const string DefaultConfigPath = "config.jsonc";

    /// <summary>The connect timeout used when <see cref="ConnectTimeoutSetting"/> is unset.</summary>
    public static readonly TimeSpan DefaultConnectTimeout = TimeSpan.FromSeconds(15);

    /// <summary>The health interval used when <see cref="HealthIntervalSetting"/> is unset.</summary>
    public static readonly TimeSpan DefaultHealthInterval = TimeSpan.FromSeconds(60);

    /// <summary>Master switch: when false the config file is never read.</summary>
    public required bool Enabled { get; init; }

    /// <summary>Resolved path to the config file.</summary>
    public required string ConfigPath { get; init; }

    /// <summary>
    /// Whether <see cref="ConfigPathSetting"/> was explicitly set. A missing *default* file
    /// disables MCP; a missing *explicit* file is fatal.
    /// </summary>
    public required bool ConfigPathExplicit { get; init; }

    /// <summary>Per-server connect + tool-discovery budget.</summary>
    public required TimeSpan ConnectTimeout { get; init; }

    /// <summary>How often the background loop pings and reconnects.</summary>
    public required TimeSpan HealthInterval { get; init; }

    /// <summary>
    /// Reads and validates the settings. A malformed boolean or duration is fatal so a
    /// misconfigured deployment fails fast.
    /// </summary>
    /// <exception cref="InvalidOperationException">
    /// Thrown when <see cref="EnabledSetting"/>, <see cref="ConnectTimeoutSetting"/> or
    /// <see cref="HealthIntervalSetting"/> is malformed.
    /// </exception>
    public static McpOptions FromConfiguration(IConfiguration configuration)
    {
        var rawPath = configuration[ConfigPathSetting];
        var explicitPath = !string.IsNullOrWhiteSpace(rawPath);

        return new McpOptions
        {
            Enabled = ParseEnabled(configuration[EnabledSetting]),
            ConfigPath = explicitPath ? rawPath!.Trim() : DefaultConfigPath,
            ConfigPathExplicit = explicitPath,
            ConnectTimeout = DurationParser.Parse(
                configuration[ConnectTimeoutSetting], DefaultConnectTimeout, ConnectTimeoutSetting),
            HealthInterval = DurationParser.Parse(
                configuration[HealthIntervalSetting], DefaultHealthInterval, HealthIntervalSetting),
        };
    }

    private static bool ParseEnabled(string? raw)
    {
        if (string.IsNullOrWhiteSpace(raw))
        {
            return true;
        }

        return bool.TryParse(raw.Trim(), out var enabled)
            ? enabled
            : throw new InvalidOperationException(
                $"{EnabledSetting} value '{raw}' is not a valid boolean. Use true or false.");
    }
}
