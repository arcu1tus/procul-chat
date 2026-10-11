using Microsoft.Extensions.Logging.Abstractions;
using Procul.Api.Chat.Tools;
using Procul.Api.Chat.V1;
using Procul.Api.Mcp;
using Procul.Api.Tests.Support;

namespace Procul.Api.Tests.Mcp;

/// <summary>
/// Verifies the chat turn is offered the built-in tools plus the namespaced tools discovered from
/// connected MCP servers, and that server instructions are appended to the system prompt.
/// </summary>
public class ChatToolsMergeTests
{
    [Fact]
    public async Task The_turn_offers_builtins_plus_namespaced_mcp_tools()
    {
        await using var server = await McpTestServerHost.StartAsync();
        using var config = TempConfig.Write($$"""
            { "mcpServers": { "testserver": { "type": "http", "url": "{{server.Endpoint}}" } } }
            """);

        var manager = new McpClientManager(
            McpTestHelpers.Options((McpOptions.ConfigPathSetting, config.Path)),
            NullLoggerFactory.Instance,
            NullLogger<McpClientManager>.Instance);

        await manager.StartAsync(CancellationToken.None);
        try
        {
            var names = ChatStreamServiceV1.MergeTools(manager).Select(tool => tool.Name).ToList();

            Assert.Contains("get_current_time", names);
            Assert.Contains("run_python", names);
            Assert.Contains("testserver__echo", names);

            Assert.StartsWith(AgentTools.SystemPrompt, ChatStreamServiceV1.ComposeSystemPrompt(manager));
        }
        finally
        {
            await manager.StopAsync(CancellationToken.None);
        }
    }
}
