namespace Procul.Api.Tests.Support;

/// <summary>
/// Builds a temporary, valid <c>config.jsonc</c> for integration tests. Model health and capability
/// discovery are disabled by default so booting the app makes no network calls.
/// </summary>
internal static class TestConfig
{
    /// <summary>The default model slug used by the integration tests.</summary>
    public const string ModelSlug = "test/model";

    /// <summary>One valid, health-checkable model that never touches the network at boot.</summary>
    public const string DefaultModel =
        """{ "slug": "test/model", "name": "Test", "baseUrl": "https://openrouter.ai/api/v1", "apiKey": "test", "default": true, "healthCheck": true, "discoverCapabilities": false }""";

    /// <summary>Writes a config file with the given sections and returns it (delete on dispose).</summary>
    public static TempConfig Write(
        string? corsOrigins = null,
        string? connectionString = null,
        string? models = null,
        string? mcpServers = null,
        bool modelHealthEnabled = false)
    {
        var cors = string.IsNullOrWhiteSpace(corsOrigins)
            ? string.Empty
            : "\"corsAllowedOrigins\": [" + JoinOrigins(corsOrigins) + "],";
        var database = connectionString is null
            ? string.Empty
            : $"\"connectionString\": \"{connectionString}\",";

        var json = $$"""
            {
              "server": { {{cors}} "sessionLifetime": "30d" },
              "database": { {{database}} },
              "models": [ {{models ?? DefaultModel}} ],
              "modelHealth": { "enabled": {{(modelHealthEnabled ? "true" : "false")}} },
              "mcp": { "enabled": true, "connectTimeout": "2s", "healthInterval": "60s" },
              "mcpServers": {{mcpServers ?? "{}"}}
            }
            """;

        return TempConfig.Write(json);
    }

    private static string JoinOrigins(string origins) =>
        string.Join(
            ", ",
            origins
                .Split(',', StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries)
                .Select(origin => $"\"{origin}\""));
}
