using System.Net;
using Microsoft.Extensions.Logging.Abstractions;
using Procul.Api.Chat;
using Procul.Api.Chat.Models;
using Procul.Api.Tests.Support;

namespace Procul.Api.Tests.Models;

/// <summary>
/// Unit tests for the catalog/health service with fake clients and a fake HTTP factory: startup
/// probes, opt-out, the idle re-probe rule, and on-demand checks.
/// </summary>
public class ModelCatalogServiceTests
{
    private static ModelHealthOptions Options(TimeSpan? interval = null) => new()
    {
        Enabled = true,
        Interval = interval ?? TimeSpan.FromHours(1),
        Timeout = TimeSpan.FromSeconds(5),
        ProbePrompt = "alive?",
        MaxOutputTokens = 5,
    };

    private static ChatModelDefinition Definition(string slug, bool healthCheck) =>
        ChatModelTestHelpers.Definition(
            slug,
            isDefault: slug == "a",
            healthCheck: healthCheck,
            discoverCapabilities: false,
            provider: ModelProvider.OpenAiCompatible);

    private static ModelCatalogService NewService(
        ChatModelRegistry registry,
        ModelUsageTracker usage,
        ModelHealthOptions options) =>
        new(registry, NoDiscovery(), usage, options, NullLogger<ModelCatalogService>.Instance);

    private static ModelCapabilityDiscovery NoDiscovery() => new(
        new FakeHttpClientFactory(_ => new HttpResponseMessage(HttpStatusCode.InternalServerError)),
        NullLogger<ModelCapabilityDiscovery>.Instance);

    [Fact]
    public async Task Startup_probes_health_checked_models_only()
    {
        var healthy = new RecordingChatClient();
        var optedOut = new RecordingChatClient();
        var registry = ChatModelTestHelpers.Registry(
            (Definition("a", healthCheck: true), healthy),
            (Definition("b", healthCheck: false), optedOut));
        var service = NewService(registry, new ModelUsageTracker(), Options());

        await service.StartAsync(CancellationToken.None);
        try
        {
            Assert.Equal(1, healthy.ResponseCallCount);
            Assert.Equal(0, optedOut.ResponseCallCount);
            Assert.Equal(ModelHealthStatus.Healthy, service.GetHealth("a").Status);
            Assert.Equal(ModelHealthStatus.Unknown, service.GetHealth("b").Status);
        }
        finally
        {
            await service.StopAsync(CancellationToken.None);
        }
    }

    [Fact]
    public async Task Startup_records_a_failure_as_unhealthy()
    {
        var failing = new RecordingChatClient { ThrowOnCall = new InvalidOperationException("boom") };
        var registry = ChatModelTestHelpers.Registry((Definition("a", healthCheck: true), failing));
        var service = NewService(registry, new ModelUsageTracker(), Options());

        await service.StartAsync(CancellationToken.None);
        try
        {
            var health = service.GetHealth("a");
            Assert.Equal(ModelHealthStatus.Unhealthy, health.Status);
            Assert.Equal("boom", health.LastError);
        }
        finally
        {
            await service.StopAsync(CancellationToken.None);
        }
    }

    [Fact]
    public async Task Idle_pass_skips_a_model_used_within_the_interval()
    {
        var used = new RecordingChatClient();
        var untouched = new RecordingChatClient();
        var registry = ChatModelTestHelpers.Registry(
            (Definition("a", healthCheck: true), used),
            (Definition("b", healthCheck: true), untouched));
        var usage = new ModelUsageTracker();
        usage.RecordUse("a");

        var service = NewService(registry, usage, Options(interval: TimeSpan.FromHours(1)));

        await service.RunIdlePassAsync(CancellationToken.None);

        Assert.Equal(0, used.ResponseCallCount);
        Assert.Equal(1, untouched.ResponseCallCount);
    }

    [Fact]
    public async Task Idle_pass_probes_a_model_untouched_past_the_interval()
    {
        var client = new RecordingChatClient();
        var registry = ChatModelTestHelpers.Registry((Definition("a", healthCheck: true), client));
        var usage = new ModelUsageTracker();
        usage.RecordUse("a");

        // A zero-ish interval means "last used long ago" for the rule.
        var service = NewService(registry, usage, Options(interval: TimeSpan.FromMilliseconds(1)));
        await Task.Delay(5);

        await service.RunIdlePassAsync(CancellationToken.None);

        Assert.Equal(1, client.ResponseCallCount);
        Assert.Equal(ModelHealthSource.Idle, service.GetHealth("a").Source);
    }

    [Fact]
    public async Task On_demand_check_always_probes()
    {
        var client = new RecordingChatClient();
        var registry = ChatModelTestHelpers.Registry((Definition("a", healthCheck: false), client));
        var service = NewService(registry, new ModelUsageTracker(), Options());

        Assert.True(await service.CheckAsync("a", ModelHealthSource.OnDemand, CancellationToken.None));
        Assert.Equal(1, client.ResponseCallCount);
    }

    [Fact]
    public async Task On_demand_check_of_an_unknown_slug_returns_false()
    {
        var registry = ChatModelTestHelpers.Registry((Definition("a", healthCheck: true), new RecordingChatClient()));
        var service = NewService(registry, new ModelUsageTracker(), Options());

        Assert.False(await service.CheckAsync("ghost", ModelHealthSource.OnDemand, CancellationToken.None));
    }
}
