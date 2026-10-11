using Procul.Api.Mcp;
using Procul.Api.Tests.Support;

namespace Procul.Api.Tests.Mcp;

/// <summary>Unit tests for reading and validating the MCP settings.</summary>
public class McpOptionsTests
{
    [Fact]
    public void Defaults_are_enabled_with_the_default_path_and_timeouts()
    {
        var options = McpTestHelpers.Options();

        Assert.True(options.Enabled);
        Assert.Equal(McpOptions.DefaultConfigPath, options.ConfigPath);
        Assert.False(options.ConfigPathExplicit);
        Assert.Equal(TimeSpan.FromSeconds(15), options.ConnectTimeout);
        Assert.Equal(TimeSpan.FromSeconds(60), options.HealthInterval);
    }

    [Fact]
    public void Reads_an_explicit_path_and_switch()
    {
        var options = McpTestHelpers.Options(
            (McpOptions.ConfigPathSetting, "/etc/procul/config.jsonc"),
            (McpOptions.EnabledSetting, "false"),
            (McpOptions.ConnectTimeoutSetting, "30s"),
            (McpOptions.HealthIntervalSetting, "5m"));

        Assert.False(options.Enabled);
        Assert.Equal("/etc/procul/config.jsonc", options.ConfigPath);
        Assert.True(options.ConfigPathExplicit);
        Assert.Equal(TimeSpan.FromSeconds(30), options.ConnectTimeout);
        Assert.Equal(TimeSpan.FromMinutes(5), options.HealthInterval);
    }

    [Fact]
    public void A_malformed_boolean_fails_fast() =>
        Assert.Throws<InvalidOperationException>(
            () => McpTestHelpers.Options((McpOptions.EnabledSetting, "maybe")));

    [Fact]
    public void A_malformed_duration_fails_fast() =>
        Assert.Throws<InvalidOperationException>(
            () => McpTestHelpers.Options((McpOptions.ConnectTimeoutSetting, "soon")));
}
