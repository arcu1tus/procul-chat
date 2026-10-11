using Procul.Api.Configuration;

namespace Procul.Api.Chat;

/// <summary>The provider kind a model is reached through.</summary>
public enum ModelProvider
{
    /// <summary>OpenRouter (<c>/models</c> capability discovery is available).</summary>
    OpenRouter,

    /// <summary>Any OpenAI-compatible endpoint.</summary>
    OpenAiCompatible,
}

/// <summary>An input modality a model accepts.</summary>
public enum ModelInputModality
{
    Text,
    Image,
    Audio,
    Video,
    Pdf,
}

/// <summary>
/// A validated, secret-resolved model entry: one configured model plus its per-slug
/// <see cref="Microsoft.Extensions.AI.IChatClient"/> (owned by <see cref="ChatModelRegistry"/>).
/// </summary>
public sealed record ChatModelDefinition(
    string Slug,
    string Name,
    string? Description,
    string BaseUrl,
    string? ApiKey,
    ModelProvider Provider,
    IReadOnlySet<ModelInputModality> DeclaredCapabilities,
    bool IsDefault,
    bool HealthCheck,
    bool DiscoverCapabilities,
    int? MaxOutputTokens
)
{
    /// <summary>Builds the validated definitions from the config (already domain-validated).</summary>
    public static IReadOnlyList<ChatModelDefinition> CreateAll(ProculConfig config) =>
        [.. config.Models.Select(Create)];

    private static ChatModelDefinition Create(ChatModelConfig model)
    {
        var slug = model.Slug!.Trim();
        return new ChatModelDefinition(
            Slug: slug,
            Name: string.IsNullOrWhiteSpace(model.Name) ? slug : model.Name!.Trim(),
            Description: model.Description,
            BaseUrl: model.BaseUrl!.Trim(),
            ApiKey: model.ApiKey,
            Provider: ParseProvider(model.Provider, model.BaseUrl!),
            DeclaredCapabilities: ParseCapabilities(model.Capabilities),
            IsDefault: model.Default,
            HealthCheck: model.HealthCheck,
            DiscoverCapabilities: model.DiscoverCapabilities,
            MaxOutputTokens: model.MaxOutputTokens);
    }

    /// <summary>Parses a provider name, inferring it from the base URL when omitted.</summary>
    public static ModelProvider ParseProvider(string? provider, string baseUrl)
    {
        if (!string.IsNullOrWhiteSpace(provider))
        {
            return provider.Trim().ToLowerInvariant() switch
            {
                "openrouter" => ModelProvider.OpenRouter,
                "openai-compatible" => ModelProvider.OpenAiCompatible,
                _ => ModelProvider.OpenAiCompatible,
            };
        }

        return baseUrl.Contains("openrouter.ai", StringComparison.OrdinalIgnoreCase)
            ? ModelProvider.OpenRouter
            : ModelProvider.OpenAiCompatible;
    }

    /// <summary>Parses declared capabilities; text is the baseline when none are declared.</summary>
    public static IReadOnlySet<ModelInputModality> ParseCapabilities(IEnumerable<string>? capabilities)
    {
        var parsed = new HashSet<ModelInputModality>();
        foreach (var capability in capabilities ?? [])
        {
            if (TryParseModality(capability, out var modality))
            {
                parsed.Add(modality);
            }
        }

        if (parsed.Count == 0)
        {
            parsed.Add(ModelInputModality.Text);
        }

        return parsed;
    }

    /// <summary>Maps an OpenRouter/config modality string to the enum.</summary>
    public static bool TryParseModality(string? value, out ModelInputModality modality)
    {
        switch (value?.Trim().ToLowerInvariant())
        {
            case "text":
                modality = ModelInputModality.Text;
                return true;
            case "image":
                modality = ModelInputModality.Image;
                return true;
            case "audio":
                modality = ModelInputModality.Audio;
                return true;
            case "video":
                modality = ModelInputModality.Video;
                return true;
            case "pdf" or "file":
                modality = ModelInputModality.Pdf;
                return true;
            default:
                modality = default;
                return false;
        }
    }
}
