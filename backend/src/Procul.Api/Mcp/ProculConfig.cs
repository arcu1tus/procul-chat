namespace Procul.Api.Mcp;

/// <summary>
/// The shape of <c>config.jsonc</c>. Only <c>mcpServers</c> is defined today; more top-level
/// sections can be added alongside it without changing the loader's contract.
/// </summary>
public sealed class ProculConfig
{
    /// <summary>Configured MCP servers, keyed by the operator's chosen name.</summary>
    public Dictionary<string, McpServerConfig> McpServers { get; set; } = new();
}
