using Microsoft.Extensions.AI;
using Procul.Api.Configuration;
using Procul.Api.Images;
using Procul.Api.Mcp;
using ImageGenerationOptions = Procul.Api.Configuration.ImageGenerationOptions;
using ImageGenerationRequest = Procul.Api.Images.ImageGenerationRequest;

namespace Procul.Api.Chat.Tools;

/// <summary>
/// Builds the tools offered on a single turn. The built-ins (time, Python) are static; the media
/// tools need the scoped <c>ProculDbContext</c>/<c>IAttachmentStore</c> and the turn's event sink,
/// so they are constructed per turn from a <see cref="TurnToolContext"/>. MCP tools are appended
/// unchanged.
/// </summary>
internal sealed class TurnToolFactory(
    IHttpClientFactory httpClientFactory,
    ImageGenerationOptions imageOptions,
    IImageGenerationClient imageClient,
    IRemoteUrlPolicy urlPolicy,
    ILogger<TurnToolFactory> logger)
{
    /// <summary>Whether the <c>generate_image</c> tool is offered this turn.</summary>
    public bool ImageGenerationEnabled => imageOptions.Enabled;

    /// <summary>The tools for this turn: built-ins, media tools, then every MCP tool.</summary>
    public IList<AITool> BuildTurnTools(TurnToolContext context, McpClientManager mcp)
    {
        var tools = new List<AITool>(AgentTools.All);

        if (imageOptions.Enabled)
        {
            tools.Add(new ImageGenerationTool(imageClient, imageOptions, context, logger).Create());
        }

        tools.Add(new ShowImageTool(httpClientFactory, urlPolicy, context, logger).Create());
        tools.AddRange(mcp.Tools);
        return tools;
    }

    /// <summary>The system prompt for a turn: base prompt (+ media-tool notes) + MCP instructions.</summary>
    public string ComposeSystemPrompt(McpClientManager mcp) =>
        AgentTools.SystemPromptFor(imageOptions.Enabled) + mcp.SystemPromptSuffix;

    /// <summary>
    /// Test seam: a factory whose image generation is disabled and whose media tools use permissive
    /// dependencies, so a test can drive a turn without a real provider.
    /// </summary>
    internal static TurnToolFactory CreateForTests(
        ImageGenerationOptions? imageOptions = null,
        IImageGenerationClient? imageClient = null,
        IHttpClientFactory? httpClientFactory = null,
        IRemoteUrlPolicy? urlPolicy = null) =>
        new(
            httpClientFactory ?? new TestHttpClientFactory(),
            imageOptions ?? ImageGenerationOptions.FromConfig(new ProculConfig()),
            imageClient ?? new UnavailableImageGenerationClient(),
            urlPolicy ?? new PermissiveRemoteUrlPolicy(),
            Microsoft.Extensions.Logging.Abstractions.NullLogger<TurnToolFactory>.Instance);

    private sealed class TestHttpClientFactory : IHttpClientFactory
    {
        public HttpClient CreateClient(string name) => new(new NotFoundHandler());

        private sealed class NotFoundHandler : HttpMessageHandler
        {
            protected override Task<HttpResponseMessage> SendAsync(
                HttpRequestMessage request, CancellationToken cancellationToken) =>
                Task.FromResult(new HttpResponseMessage(System.Net.HttpStatusCode.NotFound));
        }
    }

    private sealed class UnavailableImageGenerationClient : IImageGenerationClient
    {
        public Task<GeneratedImage> GenerateAsync(ImageGenerationRequest request, CancellationToken ct) =>
            throw new ImageGenerationException("Image generation is not configured.");
    }
}
