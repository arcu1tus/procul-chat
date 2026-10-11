using Procul.Api.Chat.Models;
using Procul.Api.Chat.V1;
using Procul.Api.Configuration;

namespace Procul.Api.Chat;

public static class ChatServiceCollectionExtensions
{
    /// <summary>
    /// Registers the multi-model registry (one <see cref="Microsoft.Extensions.AI.IChatClient"/>
    /// per configured model), the conversation-turn service, and the model catalog/health services.
    /// </summary>
    public static IServiceCollection AddProculChat(
        this IServiceCollection services,
        ProculConfig config)
    {
        services.AddSingleton<ChatModelRegistry>();
        services.AddScoped<ChatStreamServiceV1>();

        services.AddSingleton<ModelUsageTracker>();
        services.AddSingleton(ModelHealthOptions.FromConfig(config));
        services.AddHttpClient();
        services.AddSingleton<ModelCapabilityDiscovery>();
        services.AddSingleton<ModelCatalogService>();
        services.AddHostedService(sp => sp.GetRequiredService<ModelCatalogService>());

        return services;
    }
}
