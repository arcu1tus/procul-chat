using Procul.Api.Configuration;

namespace Procul.Api.Mcp;

/// <summary>
/// Registers the MCP client support. The manager is always registered (so the chat turn can
/// inject it even when MCP is disabled), and started as a hosted service before the server
/// begins serving traffic.
/// </summary>
public static class McpServiceCollectionExtensions
{
    /// <summary>
    /// Derives <see cref="McpOptions"/> from the config and wires the singleton
    /// <see cref="McpClientManager"/> plus its hosted-service lifetime.
    /// </summary>
    /// <exception cref="InvalidOperationException">
    /// Thrown when a setting is malformed, so a misconfigured deployment fails fast.
    /// </exception>
    public static IServiceCollection AddProculMcp(
        this IServiceCollection services,
        ProculConfig config)
    {
        var options = McpOptions.FromConfig(config);
        services.AddSingleton(options);
        services.AddSingleton<McpClientManager>();
        services.AddHostedService(sp => sp.GetRequiredService<McpClientManager>());
        return services;
    }
}
