using System.Collections.Frozen;
using Procul.Api.Chat.Models;

namespace Procul.Api.Chat;

/// <summary>The immutable model and input capabilities accepted for one turn.</summary>
internal sealed record ResolvedChatModel(ChatModelDefinition Definition, IReadOnlySet<ModelInputModality> Input)
{
    public static ResolvedChatModel Resolve(ChatModelRegistry registry, ModelCatalogService catalog, string? slug)
    {
        var definition = registry.ResolveOrDefault(slug);
        return new(definition, catalog.GetCapabilities(definition).Input.ToFrozenSet());
    }
}
