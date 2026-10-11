using System.Collections.Concurrent;

namespace Procul.Api.Chat.Models;

/// <summary>
/// Records the last time each model was used by a real request (reply or title call). The catalog
/// service reads this so the idle re-probe never burns tokens on a model that live traffic just
/// exercised.
/// </summary>
public sealed class ModelUsageTracker
{
    private readonly ConcurrentDictionary<string, DateTimeOffset> _lastUsedBySlug =
        new(StringComparer.Ordinal);

    /// <summary>Stamps a model as used "now". Called on every real turn and title call.</summary>
    public void RecordUse(string slug) => _lastUsedBySlug[slug] = DateTimeOffset.UtcNow;

    /// <summary>When the model was last used, or null when it never has been.</summary>
    public DateTimeOffset? LastUsed(string slug) =>
        _lastUsedBySlug.TryGetValue(slug, out var at) ? at : null;

    /// <summary>Whether the model was used within <paramref name="window"/> of now.</summary>
    public bool UsedWithin(string slug, TimeSpan window) =>
        LastUsed(slug) is { } at && DateTimeOffset.UtcNow - at < window;
}
