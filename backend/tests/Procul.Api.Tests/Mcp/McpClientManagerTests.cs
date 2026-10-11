using System.Text.Json;
using Microsoft.Extensions.AI;
using Procul.Api.Mcp;
using Procul.Api.Tests.Support;

namespace Procul.Api.Tests.Mcp;

/// <summary>
/// End-to-end client test: hosts a tiny MCP server in-process (Streamable HTTP, loopback only),
/// points a real <see cref="McpClientManager"/> at it, and asserts both tool discovery and
/// invocation. No external network is involved.
/// </summary>
public class McpClientManagerTests
{
    [Fact]
    public async Task Discovers_and_invokes_a_tool_from_a_live_server()
    {
        await using var server = await McpTestServerHost.StartAsync();

        var manager = McpTestHelpers.Manager(McpTestHelpers.Config(new Dictionary<string, McpServerConfig>
        {
            ["testserver"] = new() { Type = "http", Url = server.Endpoint.ToString() },
        }));

        await manager.StartAsync(CancellationToken.None);
        try
        {
            var status = Assert.Single(manager.GetStatuses());
            Assert.True(status.Connected, status.LastError);
            Assert.Equal("testserver", status.Name);
            Assert.Equal("http", status.Type);
            Assert.Contains("echo", status.Tools);

            var tool = (AIFunction)Assert.Single(manager.Tools);
            Assert.Equal("testserver__echo", tool.Name);

            var result = await tool.InvokeAsync(
                new AIFunctionArguments { ["text"] = "hi" },
                CancellationToken.None);

            Assert.Contains("echo: hi", AsText(result));
        }
        finally
        {
            await manager.StopAsync(CancellationToken.None);
        }
    }

    [Fact]
    public async Task A_down_server_is_marked_unavailable_and_does_not_throw()
    {
        // Nothing is listening on this port; connecting must fail without killing startup.
        var manager = McpTestHelpers.Manager(
            McpTestHelpers.Config(
                new Dictionary<string, McpServerConfig>
                {
                    ["dead"] = new() { Type = "http", Url = "http://127.0.0.1:1/mcp" },
                },
                connectTimeout: "2s"));

        await manager.StartAsync(CancellationToken.None);
        try
        {
            var status = Assert.Single(manager.GetStatuses());
            Assert.False(status.Connected);
            Assert.NotNull(status.LastError);
            Assert.Empty(manager.Tools);
        }
        finally
        {
            await manager.StopAsync(CancellationToken.None);
        }
    }

    private static string AsText(object? result) => result switch
    {
        null => string.Empty,
        string text => text,
        JsonElement { ValueKind: JsonValueKind.String } element => element.GetString() ?? string.Empty,
        JsonElement element => element.GetRawText(),
        _ => result.ToString() ?? string.Empty,
    };
}
