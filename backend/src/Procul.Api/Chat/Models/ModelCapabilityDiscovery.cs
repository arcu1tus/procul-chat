using System.Collections.Concurrent;
using System.Net.Http.Headers;
using System.Text.Json;

namespace Procul.Api.Chat.Models;

/// <summary>
/// Discovers a model's capabilities from its provider's <c>/models</c> endpoint (OpenRouter, or any
/// endpoint when <c>discoverCapabilities</c> is set). Discovery is best-effort: any failure falls
/// back to the declared capabilities and is never fatal. Results are cached per slug.
/// </summary>
public sealed class ModelCapabilityDiscovery
{
    private readonly IHttpClientFactory _httpClientFactory;
    private readonly ILogger<ModelCapabilityDiscovery> _logger;
    private readonly ConcurrentDictionary<string, DiscoveredCapabilities?> _cache = new(StringComparer.Ordinal);

    public ModelCapabilityDiscovery(
        IHttpClientFactory httpClientFactory,
        ILogger<ModelCapabilityDiscovery> logger)
    {
        _httpClientFactory = httpClientFactory;
        _logger = logger;
    }

    /// <summary>
    /// Returns the discovered capabilities for <paramref name="definition"/>, or null when
    /// discovery is disabled or fails.
    /// </summary>
    public async Task<DiscoveredCapabilities?> DiscoverAsync(
        ChatModelDefinition definition,
        CancellationToken ct)
    {
        if (_cache.TryGetValue(definition.Slug, out var cached))
        {
            return cached;
        }

        var discovered = await FetchAsync(definition, ct);
        _cache[definition.Slug] = discovered;
        return discovered;
    }

    private async Task<DiscoveredCapabilities?> FetchAsync(ChatModelDefinition definition, CancellationToken ct)
    {
        // OpenRouter always exposes /models; other providers only when explicitly opted in.
        if (definition.Provider != ModelProvider.OpenRouter && !definition.DiscoverCapabilities)
        {
            return null;
        }

        try
        {
            var client = _httpClientFactory.CreateClient();
            var url = definition.BaseUrl.TrimEnd('/') + "/models";

            using var request = new HttpRequestMessage(HttpMethod.Get, url);
            if (!string.IsNullOrEmpty(definition.ApiKey))
            {
                request.Headers.Authorization = new AuthenticationHeaderValue("Bearer", definition.ApiKey);
            }

            using var response = await client.SendAsync(request, ct);
            if (!response.IsSuccessStatusCode)
            {
                _logger.LogInformation(
                    "Model capability discovery for '{Slug}' returned {Status}; using declared capabilities.",
                    definition.Slug, (int)response.StatusCode);
                return null;
            }

            await using var stream = await response.Content.ReadAsStreamAsync(ct);
            using var document = await JsonDocument.ParseAsync(stream, cancellationToken: ct);
            return Parse(document.RootElement, definition.Slug);
        }
        catch (OperationCanceledException) when (ct.IsCancellationRequested)
        {
            throw;
        }
        catch (Exception ex)
        {
            _logger.LogInformation(
                ex, "Model capability discovery for '{Slug}' failed; using declared capabilities.",
                definition.Slug);
            return null;
        }
    }

    /// <summary>
    /// Parses either the OpenRouter <c>{ "data": [...] }</c> shape or a bare array, matching the
    /// model by <c>id</c> or <c>canonical_slug</c>.
    /// </summary>
    internal static DiscoveredCapabilities? Parse(JsonElement root, string slug)
    {
        JsonElement entries;
        if (root.ValueKind == JsonValueKind.Array)
        {
            entries = root;
        }
        else if (root.ValueKind == JsonValueKind.Object
            && root.TryGetProperty("data", out var data)
            && data.ValueKind == JsonValueKind.Array)
        {
            entries = data;
        }
        else
        {
            return null;
        }

        foreach (var entry in entries.EnumerateArray())
        {
            if (entry.ValueKind != JsonValueKind.Object || !Matches(entry, slug))
            {
                continue;
            }

            var input = new HashSet<ModelInputModality>();
            var output = new List<string>();

            if (entry.TryGetProperty("architecture", out var architecture)
                && architecture.ValueKind == JsonValueKind.Object)
            {
                ReadModalities(architecture, "input_modalities", input);
                ReadStrings(architecture, "output_modalities", output);
            }

            var parameters = new List<string>();
            ReadStrings(entry, "supported_parameters", parameters);

            return new DiscoveredCapabilities(input, output, parameters);
        }

        return null;
    }

    private static bool Matches(JsonElement entry, string slug)
    {
        return Matches(entry, "id", slug) || Matches(entry, "canonical_slug", slug);
    }

    private static bool Matches(JsonElement entry, string property, string slug) =>
        entry.TryGetProperty(property, out var value)
        && value.ValueKind == JsonValueKind.String
        && string.Equals(value.GetString(), slug, StringComparison.Ordinal);

    private static void ReadModalities(JsonElement owner, string property, HashSet<ModelInputModality> target)
    {
        if (!owner.TryGetProperty(property, out var array) || array.ValueKind != JsonValueKind.Array)
        {
            return;
        }

        foreach (var item in array.EnumerateArray())
        {
            if (item.ValueKind == JsonValueKind.String
                && ChatModelDefinition.TryParseModality(item.GetString(), out var modality))
            {
                target.Add(modality);
            }
        }
    }

    private static void ReadStrings(JsonElement owner, string property, List<string> target)
    {
        if (!owner.TryGetProperty(property, out var array) || array.ValueKind != JsonValueKind.Array)
        {
            return;
        }

        foreach (var item in array.EnumerateArray())
        {
            if (item.ValueKind == JsonValueKind.String && item.GetString() is { } text)
            {
                target.Add(text);
            }
        }
    }
}
