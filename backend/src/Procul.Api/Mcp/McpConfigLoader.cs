namespace Procul.Api.Mcp;

/// <summary>The transport an MCP server is reached over. Remote only: no stdio.</summary>
public enum McpTransportType
{
    /// <summary>Streamable HTTP (the current MCP HTTP transport).</summary>
    StreamableHttp,

    /// <summary>Legacy HTTP + SSE transport.</summary>
    Sse,
}

/// <summary>A validated, secret-resolved MCP server entry ready to connect to.</summary>
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
/// Validates the <c>mcpServers</c> section of the already-parsed, secret-resolved
/// <c>config.jsonc</c>. Any problem is fatal: a misconfigured deployment should crash rather than
/// silently run without its tools.
/// </summary>
internal static class McpConfigLoader
{
    /// <summary>
    /// Validates the configured servers. A blank name, an unknown <c>type</c>, a missing or
    /// non-absolute <c>url</c>, or a blank header name is fatal. Disabled servers are skipped.
    /// </summary>
    /// <exception cref="InvalidOperationException">
    /// Thrown for a blank server name, an unknown type, a missing URL, a blank header name, or an
    /// invalid URL.
    /// </exception>
    public static IReadOnlyList<McpServerDefinition> Load(
        IReadOnlyDictionary<string, McpServerConfig> servers,
        ILogger logger)
    {
        var definitions = new List<McpServerDefinition>();

        foreach (var (name, server) in servers)
        {
            if (string.IsNullOrWhiteSpace(name))
            {
                throw new InvalidOperationException(
                    "config.jsonc contains an MCP server with a blank name.");
            }

            if (!server.Enabled)
            {
                logger.LogInformation("mcp[{Name}]: disabled in config; skipping.", name);
                continue;
            }

            definitions.Add(Validate(name, server));
        }

        if (definitions.Count == 0)
        {
            logger.LogInformation("MCP: no enabled servers configured.");
        }

        return definitions;
    }

    private static McpServerDefinition Validate(string name, McpServerConfig server)
    {
        var type = ParseType(name, server.Type);

        if (string.IsNullOrWhiteSpace(server.Url))
        {
            throw new InvalidOperationException($"MCP server '{name}' is missing 'url'.");
        }

        var url = server.Url.Trim();
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

            headers[header] = value;
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
}
