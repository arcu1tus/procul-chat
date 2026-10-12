using Procul.Api.Chat.Tools;
using Procul.Api.Configuration;

namespace Procul.Api.Images;

/// <summary>Wires the image-generation client, its options, and the outbound URL policy into DI.</summary>
public static class ImageGenerationServiceCollectionExtensions
{
    /// <summary>
    /// Registers <see cref="ImageGenerationOptions"/> plus the <see cref="IImageGenerationClient"/>
    /// matching <c>imageGeneration.provider</c>. The client is only ever called when the tool is
    /// enabled; registering it unconditionally keeps DI side-effect-free and the startup cheap.
    /// </summary>
    public static IServiceCollection AddProculImageGeneration(
        this IServiceCollection services,
        ProculConfig config)
    {
        var options = ImageGenerationOptions.FromConfig(config);
        services.AddSingleton(options);

        services.AddHttpClient();
        services.AddHttpClient(HttpImageGenerationClient.ClientName);

        services.AddSingleton<IRemoteUrlPolicy, SsrfRemoteUrlPolicy>();

        services.AddSingleton<IImageGenerationClient>(sp =>
            string.Equals(options.Provider, "openai-compatible", StringComparison.OrdinalIgnoreCase)
                ? new OpenAiCompatibleImageClient(
                    sp.GetRequiredService<IHttpClientFactory>(), options)
                : new OpenRouterImageClient(
                    sp.GetRequiredService<IHttpClientFactory>(), options));

        // The per-turn tool factory (built-in tools + media tools + MCP).
        services.AddSingleton<TurnToolFactory>();

        return services;
    }
}
