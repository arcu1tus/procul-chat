using Procul.Api.Mcp;

namespace Procul.Api.Tests.Mcp;

/// <summary>Unit tests for MCP tool namespacing, sanitization and collision resolution.</summary>
public class McpToolNamingTests
{
    [Theory]
    [InlineData("search repos", "search_repos")]
    [InlineData("weird.name/with:chars", "weird_name_with_chars")]
    [InlineData("already_ok-name", "already_ok-name")]
    public void Sanitize_replaces_invalid_characters(string raw, string expected)
    {
        Assert.Equal(expected, McpToolNaming.Sanitize(raw));
    }

    [Fact]
    public void Qualify_prefixes_the_server_name()
    {
        Assert.Equal("github__search_repositories", McpToolNaming.Qualify("github", "search_repositories"));
    }

    [Fact]
    public void Qualify_truncates_to_the_openai_limit()
    {
        var name = McpToolNaming.Qualify(new string('s', 40), new string('t', 40));

        Assert.Equal(64, name.Length);
    }

    [Fact]
    public void Assign_suffixes_collisions()
    {
        var assigner = new McpToolNameAssigner();

        var first = assigner.Assign("github", "search");
        var second = assigner.Assign("github", "search");
        var third = assigner.Assign("github", "search");

        Assert.Equal("github__search", first);
        Assert.Equal("github__search_2", second);
        Assert.Equal("github__search_3", third);
    }

    [Fact]
    public void Assign_keeps_names_unique_when_the_base_is_truncated()
    {
        var assigner = new McpToolNameAssigner();
        var server = new string('s', 40);
        var tool = new string('t', 40);

        var first = assigner.Assign(server, tool);
        var second = assigner.Assign(server, tool);

        Assert.Equal(64, first.Length);
        Assert.Equal(64, second.Length);
        Assert.NotEqual(first, second);
        Assert.EndsWith("_2", second);
    }

    [Fact]
    public void Assign_separates_tools_from_different_servers()
    {
        var assigner = new McpToolNameAssigner();

        var a = assigner.Assign("alpha", "run");
        var b = assigner.Assign("beta", "run");

        Assert.Equal("alpha__run", a);
        Assert.Equal("beta__run", b);
    }
}
