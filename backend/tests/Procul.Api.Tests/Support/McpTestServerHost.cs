using Microsoft.AspNetCore.Builder;
using Microsoft.AspNetCore.Hosting;
using Microsoft.AspNetCore.Hosting.Server;
using Microsoft.AspNetCore.Hosting.Server.Features;
using Microsoft.Extensions.DependencyInjection;
using ModelContextProtocol.Server;

namespace Procul.Api.Tests.Support;

/// <summary>
/// Hosts a tiny MCP server (Streamable HTTP) in-process on an ephemeral loopback port so the
/// client can be exercised end-to-end without any external network. Exposes one <c>echo</c> tool.
/// </summary>
internal sealed class McpTestServerHost : IAsyncDisposable
{
    private readonly WebApplication _app;

    private McpTestServerHost(WebApplication app, Uri endpoint)
    {
        _app = app;
        Endpoint = endpoint;
    }

    /// <summary>The full URL of the MCP endpoint (e.g. <c>http://127.0.0.1:1234/mcp</c>).</summary>
    public Uri Endpoint { get; }

    public static async Task<McpTestServerHost> StartAsync()
    {
        var builder = WebApplication.CreateSlimBuilder();
        builder.WebHost.UseSetting(WebHostDefaults.ServerUrlsKey, "http://127.0.0.1:0");

        var echo = McpServerTool.Create(
            (string text) => $"echo: {text}",
            new McpServerToolCreateOptions { Name = "echo", Description = "Echoes its input." });

        builder.Services.AddMcpServer().WithHttpTransport().WithTools([echo]);

        var app = builder.Build();
        app.MapMcp("/mcp");

        await app.StartAsync();

        var addresses = app.Services
            .GetRequiredService<IServer>()
            .Features.Get<IServerAddressesFeature>()!
            .Addresses;

        return new McpTestServerHost(app, new Uri($"{addresses.First().TrimEnd('/')}/mcp"));
    }

    public async ValueTask DisposeAsync()
    {
        await _app.StopAsync();
        await _app.DisposeAsync();
    }
}
