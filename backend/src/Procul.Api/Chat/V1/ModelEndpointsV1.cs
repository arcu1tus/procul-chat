using Microsoft.AspNetCore.Http.HttpResults;
using Procul.Api.Chat.Models;

namespace Procul.Api.Chat.V1;

internal static class ModelEndpointsV1
{
    public static RouteGroupBuilder MapModelsV1(this RouteGroupBuilder group)
    {
        group.MapGet("/", GetModels);

        // Model slugs may contain '/' (e.g. "vendor/model"), so a plain "{slug}" segment cannot
        // capture them and a catch-all must be the final segment. The catch-all therefore covers
        // both the check-all and check-one paths:
        //   POST /models/check                    -> re-probe every model
        //   POST /models/{slug}/check             -> re-probe one model
        group.MapPost("/{**rest}", CheckAsync);
        return group;
    }

    /// <summary>Lists the configured models with capabilities and live health (never secrets).</summary>
    private static Ok<GetModelsResponseV1> GetModels(
        ChatModelRegistry registry,
        ModelCatalogService catalog
    ) => TypedResults.Ok(Build(registry, catalog));

    /// <summary>
    /// Re-probes one model (path <c>{slug}/check</c>) or every model (path <c>check</c>).
    /// </summary>
    private static async Task<Results<Ok<GetModelsResponseV1>, Ok<ModelV1>, NotFound>> CheckAsync(
        string? rest,
        ChatModelRegistry registry,
        ModelCatalogService catalog,
        CancellationToken ct
    )
    {
        var path = (rest ?? string.Empty).Trim('/');

        if (string.Equals(path, "check", StringComparison.Ordinal))
        {
            await catalog.CheckAllAsync(ModelHealthSource.OnDemand, ct);
            return TypedResults.Ok(Build(registry, catalog));
        }

        const string suffix = "/check";
        if (path.EndsWith(suffix, StringComparison.Ordinal))
        {
            var slug = path[..^suffix.Length];
            var definition = registry.Get(slug);
            if (definition is null)
            {
                return TypedResults.NotFound();
            }

            await catalog.CheckAsync(slug, ModelHealthSource.OnDemand, ct);
            return TypedResults.Ok(ToModelV1(definition, catalog));
        }

        return TypedResults.NotFound();
    }

    private static GetModelsResponseV1 Build(ChatModelRegistry registry, ModelCatalogService catalog) =>
        new(
            registry.Default.Slug,
            [.. registry.All.Select(definition => ToModelV1(definition, catalog))]);

    private static ModelV1 ToModelV1(ChatModelDefinition definition, ModelCatalogService catalog)
    {
        var capabilities = catalog.GetCapabilities(definition);
        var health = catalog.GetHealth(definition.Slug);

        return new ModelV1(
            definition.Slug,
            definition.Name,
            definition.Description,
            definition.Provider == ModelProvider.OpenRouter ? "openrouter" : "openai-compatible",
            definition.IsDefault,
            new ModelCapabilitiesV1(
                [.. capabilities.Input.Select(modality => modality.ToString().ToLowerInvariant())],
                [.. capabilities.Output]),
            new ModelHealthV1(
                health.Status.ToString().ToLowerInvariant(),
                health.LastCheckedAt,
                health.LatencyMs,
                health.LastError,
                health.LastUsedAt,
                health.Source is { } source ? source.ToString().ToLowerInvariant() : null));
    }
}
