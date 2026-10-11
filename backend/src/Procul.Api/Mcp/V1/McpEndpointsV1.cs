using Microsoft.AspNetCore.Http.HttpResults;

namespace Procul.Api.Mcp.V1;

internal static class McpEndpointsV1
{
    public static RouteGroupBuilder MapMcpV1(this RouteGroupBuilder group)
    {
        group.MapGet("/servers", GetServers);
        group.MapPost("/servers/{name}/reconnect", ReconnectAsync);
        return group;
    }

    private static Ok<McpServersResponseV1> GetServers(McpClientManager mcp)
    {
        var servers = mcp.GetStatuses()
            .Select(status => new McpServerStatusV1(
                status.Name,
                status.Type,
                status.Url,
                status.Connected,
                status.ToolCount,
                [.. status.Tools],
                status.LastError,
                status.LastConnectedAt))
            .ToList();

        return TypedResults.Ok(new McpServersResponseV1(servers));
    }

    private static async Task<Results<Ok<McpReconnectResponseV1>, NotFound>> ReconnectAsync(
        string name,
        McpClientManager mcp,
        CancellationToken ct
    )
    {
        if (string.IsNullOrWhiteSpace(name))
        {
            return TypedResults.NotFound();
        }

        var known = mcp.GetStatuses()
            .Any(status => string.Equals(status.Name, name, StringComparison.OrdinalIgnoreCase));
        if (!known)
        {
            return TypedResults.NotFound();
        }

        var connected = await mcp.ReconnectAsync(name, ct);
        return TypedResults.Ok(new McpReconnectResponseV1(name, connected));
    }
}
