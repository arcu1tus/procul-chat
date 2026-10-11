using System.ClientModel;
using Microsoft.Extensions.AI;
using OpenAI;
using Procul.Api.Configuration;

namespace Procul.Api.Chat;

/// <summary>
/// Owns one <see cref="IChatClient"/> per configured model and resolves a conversation's model to
/// a definition + client. Replaces the old single-model <c>ChatModelOptions</c>.
/// </summary>
public sealed class ChatModelRegistry : IDisposable
{
    private readonly Dictionary<string, ChatModelDefinition> _bySlug;
    private readonly Dictionary<string, IChatClient> _clients;
    private readonly IReadOnlyList<ChatModelDefinition> _all;
    private readonly ChatModelDefinition _default;
    private readonly ILogger _logger;

    /// <summary>Builds the registry (and one client per model) from the validated config.</summary>
    public ChatModelRegistry(ProculConfig config, ILogger<ChatModelRegistry> logger)
        : this(ChatModelDefinition.CreateAll(config), CreateClient, logger)
    {
    }

    /// <summary>
    /// Test seam: builds the registry from explicit definitions and a client factory, so tests can
    /// supply fake clients without touching the network.
    /// </summary>
    internal ChatModelRegistry(
        IReadOnlyList<ChatModelDefinition> definitions,
        Func<ChatModelDefinition, IChatClient> clientFactory,
        ILogger logger)
    {
        if (definitions.Count == 0)
        {
            throw new InvalidOperationException("At least one model must be configured.");
        }

        _logger = logger;
        _all = [.. definitions];
        _bySlug = definitions.ToDictionary(d => d.Slug, StringComparer.Ordinal);
        _clients = definitions.ToDictionary(d => d.Slug, clientFactory, StringComparer.Ordinal);
        _default = definitions.FirstOrDefault(d => d.IsDefault) ?? definitions[0];
    }

    /// <summary>Every configured model, in config order.</summary>
    public IReadOnlyList<ChatModelDefinition> All => _all;

    /// <summary>The default model (the one marked <c>default</c>, else the first configured).</summary>
    public ChatModelDefinition Default => _default;

    /// <summary>The definition for <paramref name="slug"/>, or null when it is not configured.</summary>
    public ChatModelDefinition? Get(string slug) =>
        _bySlug.TryGetValue(slug, out var definition) ? definition : null;

    /// <summary>The client for <paramref name="slug"/>.</summary>
    /// <exception cref="KeyNotFoundException">Thrown when the slug is not configured.</exception>
    public IChatClient GetClient(string slug) => _clients[slug];

    /// <summary>
    /// Resolves a slug to a definition. Returns <c>true</c> when it matched a configured model;
    /// <c>false</c> (with <paramref name="definition"/> set to the default) when it was null or
    /// unknown.
    /// </summary>
    public bool TryResolve(string? slug, out ChatModelDefinition definition)
    {
        if (!string.IsNullOrEmpty(slug) && _bySlug.TryGetValue(slug, out var found))
        {
            definition = found;
            return true;
        }

        definition = _default;
        return false;
    }

    /// <summary>
    /// Resolves a conversation's stored slug, falling back to the default and logging a warning
    /// when the stored slug is no longer configured.
    /// </summary>
    public ChatModelDefinition ResolveOrDefault(string? slug)
    {
        if (TryResolve(slug, out var definition))
        {
            return definition;
        }

        if (!string.IsNullOrEmpty(slug))
        {
            _logger.LogWarning(
                "Conversation references model '{Slug}', which is no longer configured; " +
                "falling back to the default '{Default}'.",
                slug, _default.Slug);
        }

        return definition;
    }

    private static IChatClient CreateClient(ChatModelDefinition definition) =>
        new OpenAI.Chat.ChatClient(
            model: definition.Slug,
            credential: new ApiKeyCredential(definition.ApiKey ?? string.Empty),
            options: new OpenAIClientOptions { Endpoint = new Uri(definition.BaseUrl) }
        )
        .AsIChatClient()
        // Without this, tools in ChatOptions.Tools are never executed: the model can request a
        // tool call, but nothing runs it. UseFunctionInvocation wraps the client so tool calls are
        // handled internally and only the final assistant tokens surface to callers.
        .AsBuilder()
        .UseFunctionInvocation()
        .Build();

    /// <summary>Disposes every per-model client.</summary>
    public void Dispose()
    {
        foreach (var client in _clients.Values)
        {
            client.Dispose();
        }
    }
}
