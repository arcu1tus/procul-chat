namespace Procul.Api.Mcp;

/// <summary>
/// One entry under <c>mcpServers</c> in <c>config.jsonc</c>. Values may reference environment
/// variables as <c>${VAR}</c> (in <see cref="Url"/> and <see cref="Headers"/>), which keeps
/// tokens in <c>.env</c> and the committed JSON secret-free.
/// </summary>
public sealed class McpServerConfig
{
    /// <summary>Transport: <c>http</c> (Streamable HTTP) or <c>sse</c> (legacy). Required.</summary>
    public string? Type { get; set; }

    /// <summary>The server endpoint. Required. Supports <c>${ENV_VAR}</c> interpolation.</summary>
    public string? Url { get; set; }

    /// <summary>Static request headers (e.g. an <c>Authorization</c> bearer). Values support
    /// <c>${ENV_VAR}</c> interpolation. Never logged or returned by the API.</summary>
    public Dictionary<string, string>? Headers { get; set; }

    /// <summary>Whether to connect to this server. Optional; defaults to <c>true</c>.</summary>
    public bool Enabled { get; set; } = true;
}
