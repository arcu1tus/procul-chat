using Microsoft.EntityFrameworkCore;
using Procul.Api.Chat.Tools;
using Procul.Api.Configuration;
using Procul.Api.Infrastructure;
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

        var manager = McpTestHelpers.Manager(McpTestHelpers.Config(new Dictionary<string, McpServerConfig>
        {
            ["testserver"] = new() { Type = "http", Url = server.Endpoint.ToString() },
        }));

        await manager.StartAsync(CancellationToken.None);
        try
        {
            var factory = TurnToolFactory.CreateForTests();

            await using var db = new ProculDbContext(
                new DbContextOptionsBuilder<ProculDbContext>()
                    .UseInMemoryDatabase($"merge-{Guid.NewGuid():N}")
                    .Options);
            var context = new TurnToolContext(
                db,
                new FakeAttachmentStore(),
                TestAttachmentOptions.Create(),
                Guid.NewGuid(),
                "test/model",
                new GeneratedMediaCollector());

            var names = factory.BuildTurnTools(context, manager).Select(tool => tool.Name).ToList();

            Assert.Contains("get_current_time", names);
            Assert.Contains("run_python", names);
            Assert.Contains("show_image", names);
            Assert.Contains("testserver__echo", names);

            Assert.StartsWith(AgentTools.SystemPrompt, factory.ComposeSystemPrompt(manager));
        }
        finally
        {
            await manager.StopAsync(CancellationToken.None);
        }
    }

    [Fact]
    public void Generate_image_is_offered_only_when_enabled()
    {
        var disabled = TurnToolFactory.CreateForTests(
            imageOptions: ImageGenerationOptions.FromConfig(new ProculConfig()));
        var enabled = TurnToolFactory.CreateForTests(
            imageOptions: ImageGenerationOptions.FromConfig(new ProculConfig
            {
                ImageGeneration = new ImageGenerationConfig
                {
                    Enabled = true,
                    Model = "google/gemini-2.5-flash-image",
                },
            }));

        Assert.False(disabled.ImageGenerationEnabled);
        Assert.True(enabled.ImageGenerationEnabled);
    }
}
