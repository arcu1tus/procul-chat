using System.Text.Json;
using System.Text.RegularExpressions;

namespace Procul.Api.Mcp;

/// <summary>The transport an MCP server is reached over. Remote only: no stdio.</summary>
public enum McpTransportType
{
    /// <summary>Streamable HTTP (the current MCP HTTP transport).</summary>
    StreamableHttp,

    /// <summary>Legacy HTTP + SSE transport.</summary>
    Sse,
}

/// <summary>A validated, environment-expanded MCP server entry ready to connect to.</summary>
public sealed record McpServerDefinition(
    string Name,
    McpTransportType Type,
    string Url,
    IReadOnlyDictionary<string, string> Headers
)
{
    /// <summary>The <c>type</c> value as reported by the status endpoint.</summary>
    public string TypeName => Type == McpTransportType.Sse ? "sse" : "http";
}

/// <summary>
/// Reads <c>config.jsonc</c>, tolerating JSONC comments and trailing commas, expands
/// <c>${ENV_VAR}</c> references in URLs and headers, and validates every server. Any problem is
/// fatal: a misconfigured deployment should crash rather than silently run without its tools.
/// </summary>
internal static class McpConfigLoader
{
    private static readonly JsonSerializerOptions JsonOptions = new()
    {
        PropertyNameCaseInsensitive = true,
        ReadCommentHandling = JsonCommentHandling.Skip,
        AllowTrailingCommas = true,
    };

    private static readonly Regex EnvReference = new(
        @"\$\{([A-Za-z_][A-Za-z0-9_]*)\}", RegexOptions.Compiled);

    /// <summary>
    /// Loads and validates the configured servers.
    /// </summary>
    /// <returns>
    /// The enabled servers, or an empty list when the config file is absent (the default path
    /// only) or contains no enabled servers.
    /// </returns>
    /// <exception cref="InvalidOperationException">
    /// Thrown for a missing explicitly-set file, malformed JSON, an unresolved
    /// <c>${VAR}</c>, an unknown type, a missing URL, a blank server name, or an invalid URL.
    /// </exception>
    public static IReadOnlyList<McpServerDefinition> Load(
        McpOptions options,
        ILogger logger,
        Func<string, string?>? environment = null)
    {
        var resolveEnv = environment ?? Environment.GetEnvironmentVariable;

        if (!File.Exists(options.ConfigPath))
        {
            if (options.ConfigPathExplicit)
            {
                throw new InvalidOperationException(
                    $"{McpOptions.ConfigPathSetting} points at '{options.ConfigPath}', which does not exist.");
            }

            logger.LogInformation(
                "MCP: no config file at '{Path}'; MCP support is disabled.", options.ConfigPath);
            return [];
        }

        ProculConfig config;
        try
        {
            var json = File.ReadAllText(options.ConfigPath);
            config = JsonSerializer.Deserialize<ProculConfig>(json, JsonOptions) ?? new ProculConfig();
        }
        catch (JsonException ex)
        {
            throw new InvalidOperationException(
                $"MCP config file '{options.ConfigPath}' is not valid JSON/JSONC: {ex.Message}", ex);
        }

        var servers = new List<McpServerDefinition>();
        foreach (var (name, server) in config.McpServers)
        {
            if (string.IsNullOrWhiteSpace(name))
            {
                throw new InvalidOperationException(
                    $"MCP config file '{options.ConfigPath}' contains a server with a blank name.");
            }

            if (!server.Enabled)
            {
                logger.LogInformation("mcp[{Name}]: disabled in config; skipping.", name);
                continue;
            }

            servers.Add(Validate(name, server, resolveEnv));
        }

        if (servers.Count == 0)
        {
            logger.LogInformation(
                "MCP: config file '{Path}' has no enabled servers.", options.ConfigPath);
        }

        return servers;
    }

    private static McpServerDefinition Validate(
        string name,
        McpServerConfig server,
        Func<string, string?> resolveEnv)
    {
        var type = ParseType(name, server.Type);

        if (string.IsNullOrWhiteSpace(server.Url))
        {
            throw new InvalidOperationException($"MCP server '{name}' is missing 'url'.");
        }

        var url = Expand(server.Url.Trim(), $"server '{name}' url", resolveEnv);
        if (!Uri.TryCreate(url, UriKind.Absolute, out var uri)
            || (uri.Scheme != Uri.UriSchemeHttp && uri.Scheme != Uri.UriSchemeHttps))
        {
            throw new InvalidOperationException(
                $"MCP server '{name}' has an invalid 'url' ('{url}'); it must be an absolute http(s) URL.");
        }

        var headers = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);
        foreach (var (header, value) in server.Headers ?? [])
        {
            if (string.IsNullOrWhiteSpace(header))
            {
                throw new InvalidOperationException(
                    $"MCP server '{name}' has a header with a blank name.");
            }

            headers[header] = Expand(value, $"server '{name}' header '{header}'", resolveEnv);
        }

        return new McpServerDefinition(name.Trim(), type, url, headers);
    }

    private static McpTransportType ParseType(string name, string? type) => type?.Trim().ToLowerInvariant() switch
    {
        "http" or "streamable-http" or "streamablehttp" => McpTransportType.StreamableHttp,
        "sse" => McpTransportType.Sse,
        null or "" => throw new InvalidOperationException(
            $"MCP server '{name}' is missing 'type'. Use \"http\" or \"sse\"."),
        _ => throw new InvalidOperationException(
            $"MCP server '{name}' has unknown type '{type}'. Use \"http\" or \"sse\"."),
    };

    /// <summary>
    /// Replaces <c>${VAR}</c> references with process-environment values. A reference to an
    /// unset variable is fatal and names the variable, so a missing token is obvious at startup.
    /// </summary>
    private static string Expand(string value, string context, Func<string, string?> resolveEnv)
    {
        return EnvReference.Replace(value, match =>
        {
            var variable = match.Groups[1].Value;
            return resolveEnv(variable)
                ?? throw new InvalidOperationException(
                    $"MCP {context} references environment variable '{variable}', which is not set.");
        });
    }
}
