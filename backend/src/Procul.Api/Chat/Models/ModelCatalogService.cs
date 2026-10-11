using System.Collections.Concurrent;
using System.Diagnostics;
using Microsoft.Extensions.AI;

namespace Procul.Api.Chat.Models;

/// <summary>
/// Owns model capability discovery and liveness health. At startup it discovers capabilities and
/// probes each model once (unless opted out). A background loop re-probes only models that had no
/// real traffic within the interval, so live-traffic models are left alone. On-demand checks back
/// the <c>GET /v1/models</c> surface. Failures are never fatal.
/// </summary>
public sealed class ModelCatalogService : IHostedService
{
    /// <summary>Upper bound on concurrent startup probes.</summary>
    private const int MaxConcurrency = 4;

    private readonly ChatModelRegistry _registry;
    private readonly ModelCapabilityDiscovery _discovery;
    private readonly ModelUsageTracker _usage;
    private readonly ModelHealthOptions _options;
    private readonly ILogger<ModelCatalogService> _logger;

    private readonly ConcurrentDictionary<string, ModelHealthState> _states = new(StringComparer.Ordinal);
    private readonly ConcurrentDictionary<string, DiscoveredCapabilities> _discovered = new(StringComparer.Ordinal);

    private readonly CancellationTokenSource _stopping = new();
    private Task? _loop;

    public ModelCatalogService(
        ChatModelRegistry registry,
        ModelCapabilityDiscovery discovery,
        ModelUsageTracker usage,
        ModelHealthOptions options,
        ILogger<ModelCatalogService> logger)
    {
        _registry = registry;
        _discovery = discovery;
        _usage = usage;
        _options = options;
        _logger = logger;
    }

    /// <summary>Discovers capabilities and probes every model once, then starts the idle loop.</summary>
    public async Task StartAsync(CancellationToken cancellationToken)
    {
        if (!_options.Enabled)
        {
            _logger.LogInformation("Model health: disabled via 'modelHealth.enabled'.");
            return;
        }

        using var gate = new SemaphoreSlim(MaxConcurrency);
        await Task.WhenAll(_registry.All.Select(async definition =>
        {
            await gate.WaitAsync(cancellationToken);
            try
            {
                await DiscoverAsync(definition, cancellationToken);

                if (definition.HealthCheck)
                {
                    await ProbeAsync(definition, ModelHealthSource.Startup, cancellationToken);
                }
            }
            finally
            {
                gate.Release();
            }
        }));

        _loop = Task.Run(() => RunLoopAsync(_stopping.Token), CancellationToken.None);
    }

    /// <summary>Stops the idle loop.</summary>
    public async Task StopAsync(CancellationToken cancellationToken)
    {
        await _stopping.CancelAsync();

        if (_loop is not null)
        {
            try
            {
                await _loop;
            }
            catch (OperationCanceledException)
            {
                // Expected when the loop is cancelled.
            }
        }
    }

    /// <summary>Re-probes one model. Returns false when no such model is configured.</summary>
    public async Task<bool> CheckAsync(string slug, ModelHealthSource source, CancellationToken ct)
    {
        var definition = _registry.Get(slug);
        if (definition is null)
        {
            return false;
        }

        await ProbeAsync(definition, source, ct);
        return true;
    }

    /// <summary>Re-probes every model that has not opted out of health checks.</summary>
    public async Task CheckAllAsync(ModelHealthSource source, CancellationToken ct)
    {
        foreach (var definition in _registry.All)
        {
            if (ct.IsCancellationRequested)
            {
                return;
            }

            if (definition.HealthCheck)
            {
                await ProbeAsync(definition, source, ct);
            }
        }
    }

    /// <summary>The current health snapshot for one model.</summary>
    public ModelHealthState GetHealth(string slug) =>
        _states.TryGetValue(slug, out var state)
            ? state with { LastUsedAt = _usage.LastUsed(slug) }
            : ModelHealthState.Unknown(_usage.LastUsed(slug));

    /// <summary>Resolved capabilities: discovered ∪ declared (text is the fallback).</summary>
    public ResolvedCapabilities GetCapabilities(ChatModelDefinition definition)
    {
        var discovered = _discovered.TryGetValue(definition.Slug, out var found) ? found : null;

        var input = new HashSet<ModelInputModality>();
        if (discovered is not null)
        {
            input.UnionWith(discovered.Input);
        }

        input.UnionWith(definition.DeclaredCapabilities);

        var output = discovered is { Output.Count: > 0 } ? discovered.Output : ["text"];
        return new ResolvedCapabilities(input, output);
    }

    private async Task DiscoverAsync(ChatModelDefinition definition, CancellationToken ct)
    {
        if (definition.Provider != ModelProvider.OpenRouter && !definition.DiscoverCapabilities)
        {
            return;
        }

        var discovered = await _discovery.DiscoverAsync(definition, ct);
        if (discovered is not null)
        {
            _discovered[definition.Slug] = discovered;
        }
    }

    private async Task RunLoopAsync(CancellationToken cancellationToken)
    {
        while (!cancellationToken.IsCancellationRequested)
        {
            try
            {
                await Task.Delay(_options.Interval, cancellationToken);
            }
            catch (OperationCanceledException)
            {
                return;
            }

            await RunIdlePassAsync(cancellationToken);
        }
    }

    /// <summary>
    /// One idle pass: probe every health-checked model that had no real traffic within the interval.
    /// Exposed for tests so they can exercise the rule without waiting out the interval.
    /// </summary>
    internal async Task RunIdlePassAsync(CancellationToken cancellationToken)
    {
        foreach (var definition in _registry.All)
        {
            if (cancellationToken.IsCancellationRequested)
            {
                return;
            }

            if (!definition.HealthCheck)
            {
                continue;
            }

            // Idle rule: a model with real traffic inside the window is left alone.
            if (_usage.UsedWithin(definition.Slug, _options.Interval))
            {
                continue;
            }

            await ProbeAsync(definition, ModelHealthSource.Idle, cancellationToken);
        }
    }

    private async Task ProbeAsync(
        ChatModelDefinition definition,
        ModelHealthSource source,
        CancellationToken ct)
    {
        var client = _registry.GetClient(definition.Slug);
        var messages = new List<ChatMessage> { new(ChatRole.User, _options.ProbePrompt) };
        var chatOptions = new ChatOptions
        {
            MaxOutputTokens = _options.MaxOutputTokens,
            Temperature = 0,
        };

        var started = Stopwatch.GetTimestamp();
        try
        {
            using var timeout = CancellationTokenSource.CreateLinkedTokenSource(ct);
            timeout.CancelAfter(_options.Timeout);

            await client.GetResponseAsync(messages, chatOptions, timeout.Token);
            Record(definition.Slug, ModelHealthStatus.Healthy, ElapsedMs(started), null, source);
        }
        catch (OperationCanceledException) when (ct.IsCancellationRequested)
        {
            throw;
        }
        catch (Exception ex)
        {
            Record(definition.Slug, ModelHealthStatus.Unhealthy, null, Describe(ex), source);
        }
    }

    private void Record(
        string slug,
        ModelHealthStatus status,
        long? latencyMs,
        string? error,
        ModelHealthSource source)
    {
        _states[slug] = new ModelHealthState(
            status, DateTimeOffset.UtcNow, latencyMs, error, _usage.LastUsed(slug), source);

        if (status == ModelHealthStatus.Healthy)
        {
            _logger.LogInformation("Model '{Slug}': healthy ({Latency} ms, {Source}).", slug, latencyMs, source);
        }
        else
        {
            _logger.LogWarning("Model '{Slug}': unhealthy — {Error} ({Source}).", slug, error, source);
        }
    }

    private static long ElapsedMs(long startedTimestamp) =>
        (long)Stopwatch.GetElapsedTime(startedTimestamp).TotalMilliseconds;

    private static string Describe(Exception ex) => ex switch
    {
        OperationCanceledException => "timed out",
        _ => ex.Message,
    };
}
