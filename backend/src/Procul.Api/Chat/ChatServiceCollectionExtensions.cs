using System.ClientModel;
using Microsoft.Extensions.AI;
using OpenAI;
using Procul.Api.Chat.V1;

namespace Procul.Api.Chat;

public static class ChatServiceCollectionExtensions
{
    /// <summary>
    /// Registers the OpenRouter-backed <see cref="IChatClient"/> and the conversation-turn
    /// service. The model slug and API key are read once at startup; a missing value is fatal.
    /// </summary>
    public static IServiceCollection AddProculChat(
        this IServiceCollection services,
        IConfiguration configuration)
    {
        var model = configuration["OPENROUTER_MODEL_SLUG"]
            ?? throw new InvalidOperationException("The OPENROUTER_MODEL_SLUG environment variable is not set.");
        var apiKey = configuration["OPENROUTER_API_KEY"]
            ?? throw new InvalidOperationException("The OPENROUTER_API_KEY environment variable is not set.");

        services
            .AddChatClient(_ => new OpenAI.Chat.ChatClient(
                model: model,
                credential: new ApiKeyCredential(apiKey),
                options: new OpenAIClientOptions { Endpoint = new Uri("https://openrouter.ai/api/v1") }
            ).AsIChatClient())
            // Without this, tools in ChatOptions.Tools are never executed: the model can request a
            // tool call, but nothing runs it. UseFunctionInvocation wraps the client so tool calls
            // are handled internally and only the final assistant tokens surface to callers.
            .UseFunctionInvocation();

        services.AddScoped<ChatStreamServiceV1>();
        services.AddSingleton(new ChatModelOptions(model));
        return services;
    }
}
