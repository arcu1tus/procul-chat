using Procul.Api.Mcp;
using Procul.Api.Tests.Support;

namespace Procul.Api.Tests.Mcp;

/// <summary>Unit tests for deriving and validating the MCP settings from config.</summary>
public class McpOptionsTests
{
    [Fact]
    public void Defaults_are_enabled_with_the_default_timeouts()
    {
        var options = McpTestHelpers.Options();

        Assert.True(options.Enabled);
        Assert.Equal(TimeSpan.FromSeconds(15), options.ConnectTimeout);
        Assert.Equal(TimeSpan.FromSeconds(60), options.HealthInterval);
    }

    [Fact]
    public void Reads_the_switch_and_durations()
    {
        var options = McpTestHelpers.Options(
            enabled: false,
            connectTimeout: "30s",
            healthInterval: "5m");

        Assert.False(options.Enabled);
        Assert.Equal(TimeSpan.FromSeconds(30), options.ConnectTimeout);
        Assert.Equal(TimeSpan.FromMinutes(5), options.HealthInterval);
    }

    [Fact]
    public void A_malformed_duration_fails_fast() =>
        Assert.Throws<InvalidOperationException>(
            () => McpTestHelpers.Options(connectTimeout: "soon"));
}
