namespace Procul.Api.Mcp.V1;

// Versioned response DTOs for the v1 MCP endpoints. Serialized as camelCase
// (JsonSerializerDefaults.Web). Headers and tokens are never included.

/// <summary>Body of <c>GET /v{version}/mcp/servers</c>.</summary>
public sealed record McpServersResponseV1(List<McpServerStatusV1> Servers);

/// <summary>Read-only status of one configured MCP server.</summary>
public sealed record McpServerStatusV1(
    string Name,
    string Type,
    string Url,
    bool Connected,
    int ToolCount,
    List<string> Tools,
    string? LastError,
    DateTimeOffset? LastConnectedAt
);

/// <summary>Body of <c>POST /v{version}/mcp/servers/{name}/reconnect</c>.</summary>
public sealed record McpReconnectResponseV1(string Name, bool Connected);
