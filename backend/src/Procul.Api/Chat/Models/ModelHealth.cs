namespace Procul.Api.Chat.Models;

/// <summary>The liveness of a model as last observed.</summary>
public enum ModelHealthStatus
{
    Unknown,
    Healthy,
    Unhealthy,
}

/// <summary>What triggered a health observation.</summary>
public enum ModelHealthSource
{
    /// <summary>The startup probe.</summary>
    Startup,

    /// <summary>The background idle re-probe.</summary>
    Idle,

    /// <summary>An explicit <c>POST /models/.../check</c>.</summary>
    OnDemand,

    /// <summary>A real request exercised the model.</summary>
    Live,
}

/// <summary>A point-in-time, secret-free health snapshot for one model.</summary>
public sealed record ModelHealthState(
    ModelHealthStatus Status,
    DateTimeOffset? LastCheckedAt,
    long? LatencyMs,
    string? LastError,
    DateTimeOffset? LastUsedAt,
    ModelHealthSource? Source)
{
    /// <summary>The state before anything has been observed.</summary>
    public static ModelHealthState Unknown(DateTimeOffset? lastUsedAt = null) =>
        new(ModelHealthStatus.Unknown, null, null, null, lastUsedAt, null);
}

/// <summary>The resolved capabilities of a model: discovered ∪ declared input modalities, and output modalities.</summary>
public sealed record ResolvedCapabilities(
    IReadOnlySet<ModelInputModality> Input,
    IReadOnlyList<string> Output);

/// <summary>Capabilities discovered from a provider's <c>/models</c> endpoint.</summary>
public sealed record DiscoveredCapabilities(
    IReadOnlySet<ModelInputModality> Input,
    IReadOnlyList<string> Output,
    IReadOnlyList<string> SupportedParameters);
