using Procul.Api.Chat;
using Procul.Api.Configuration;

namespace Procul.Api.Tests.Chat;

/// <summary>Unit tests for model resolution in the registry.</summary>
public class ChatModelRegistryTests
{
    private static ChatModelRegistry NewRegistry(params (string Slug, bool IsDefault)[] models)
    {
        var config = new ProculConfig
        {
            Models = [.. models.Select(model => new ChatModelConfig
            {
                Slug = model.Slug,
                BaseUrl = "https://openrouter.ai/api/v1",
                ApiKey = "test",
                Default = model.IsDefault,
            })],
        };

        return new ChatModelRegistry(config, Microsoft.Extensions.Logging.Abstractions.NullLogger<ChatModelRegistry>.Instance);
    }

    [Fact]
    public void The_marked_default_wins_over_the_first_model()
    {
        var registry = NewRegistry(("a", false), ("b", true));

        Assert.Equal("b", registry.Default.Slug);
    }

    [Fact]
    public void The_first_model_is_the_default_when_none_is_marked()
    {
        var registry = NewRegistry(("a", false), ("b", false));

        Assert.Equal("a", registry.Default.Slug);
    }

    [Fact]
    public void TryResolve_finds_a_configured_slug()
    {
        var registry = NewRegistry(("a", true), ("b", false));

        Assert.True(registry.TryResolve("b", out var definition));
        Assert.Equal("b", definition.Slug);
    }

    [Theory]
    [InlineData(null)]
    [InlineData("ghost")]
    public void TryResolve_falls_back_to_the_default_for_null_or_unknown(string? slug)
    {
        var registry = NewRegistry(("a", true), ("b", false));

        Assert.False(registry.TryResolve(slug, out var definition));
        Assert.Equal("a", definition.Slug);
    }

    [Fact]
    public void Each_slug_gets_its_own_stable_client()
    {
        var registry = NewRegistry(("a", true), ("b", false));

        Assert.Same(registry.GetClient("a"), registry.GetClient("a"));
        Assert.NotSame(registry.GetClient("a"), registry.GetClient("b"));
    }

    [Fact]
    public void All_preserves_config_order() =>
        Assert.Equal(new[] { "a", "b" }, NewRegistry(("a", true), ("b", false)).All.Select(d => d.Slug));
}
