using Microsoft.Extensions.AI;
using Microsoft.Extensions.Logging.Abstractions;
using Procul.Api.Chat;
using Procul.Api.Chat.Models;
using Procul.Api.Configuration;

namespace Procul.Api.Tests.Support;

/// <summary>Helpers for building model definitions and a registry backed by fake clients.</summary>
internal static class ChatModelTestHelpers
{
    /// <summary>A minimal, valid model definition.</summary>
    public static ChatModelDefinition Definition(
        string slug = "test/model",
        bool isDefault = true,
        bool healthCheck = true,
        bool discoverCapabilities = false,
        ModelProvider provider = ModelProvider.OpenRouter,
        IEnumerable<ModelInputModality>? capabilities = null) => new(
            slug,
            slug,
            null,
            "https://openrouter.ai/api/v1",
            "test",
            provider,
            new HashSet<ModelInputModality>(capabilities ?? [ModelInputModality.Text]),
            isDefault,
            healthCheck,
            discoverCapabilities,
            null);

    /// <summary>A registry whose per-slug clients are the supplied fakes.</summary>
    public static ChatModelRegistry Registry(
        params (ChatModelDefinition Definition, IChatClient Client)[] entries)
    {
        var definitions = entries.Select(entry => entry.Definition).ToList();
        var bySlug = entries.ToDictionary(
            entry => entry.Definition.Slug, entry => entry.Client, StringComparer.Ordinal);

        return new ChatModelRegistry(
            definitions, definition => bySlug[definition.Slug], NullLogger<ChatModelRegistry>.Instance);
    }

    /// <summary>A single-model registry backed by one fake client.</summary>
    public static ChatModelRegistry Registry(IChatClient client, ChatModelDefinition? definition = null) =>
        Registry((definition ?? Definition(), client));

    /// <summary>A catalog whose discovery is a no-op and whose health service is disabled.</summary>
    public static ModelCatalogService Catalog(ChatModelRegistry registry) =>
        new(
            registry,
            new ModelCapabilityDiscovery(
                new FakeHttpClientFactory(_ => new HttpResponseMessage(System.Net.HttpStatusCode.NotFound)),
                NullLogger<ModelCapabilityDiscovery>.Instance),
            new ModelUsageTracker(),
            new ModelHealthOptions
            {
                Enabled = false,
                Interval = TimeSpan.FromMinutes(30),
                Timeout = TimeSpan.FromSeconds(1),
                ProbePrompt = "alive",
                MaxOutputTokens = 1,
            },
            NullLogger<ModelCatalogService>.Instance);
}
