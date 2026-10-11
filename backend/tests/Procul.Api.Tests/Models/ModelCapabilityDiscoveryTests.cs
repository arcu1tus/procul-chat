using System.Net;
using System.Text.Json;
using Microsoft.Extensions.Logging.Abstractions;
using Procul.Api.Chat;
using Procul.Api.Chat.Models;
using Procul.Api.Tests.Support;

namespace Procul.Api.Tests.Models;

/// <summary>
/// Unit tests for parsing the OpenRouter <c>/models</c> payload (both the <c>{ data: [...] }</c>
/// and bare-array shapes) and tolerating a non-200 response.
/// </summary>
public class ModelCapabilityDiscoveryTests
{
    private const string Entry = """
        {
          "id": "test/model",
          "canonical_slug": "test/model-canonical",
          "architecture": { "input_modalities": ["text", "image"], "output_modalities": ["text"] },
          "supported_parameters": ["temperature", "tools"]
        }
        """;

    [Fact]
    public void Parses_the_data_envelope()
    {
        var root = JsonDocument.Parse($$"""{ "data": [ {{Entry}} ] }""").RootElement;

        var discovered = ModelCapabilityDiscovery.Parse(root, "test/model");

        Assert.NotNull(discovered);
        Assert.Contains(ModelInputModality.Text, discovered!.Input);
        Assert.Contains(ModelInputModality.Image, discovered.Input);
        Assert.Equal(new[] { "text" }, discovered.Output);
        Assert.Contains("tools", discovered.SupportedParameters);
    }

    [Fact]
    public void Parses_a_bare_array()
    {
        var root = JsonDocument.Parse($$"""[ {{Entry}} ]""").RootElement;

        var discovered = ModelCapabilityDiscovery.Parse(root, "test/model");

        Assert.NotNull(discovered);
        Assert.Contains(ModelInputModality.Image, discovered!.Input);
    }

    [Fact]
    public void Matches_by_canonical_slug()
    {
        var root = JsonDocument.Parse($$"""[ {{Entry}} ]""").RootElement;

        var discovered = ModelCapabilityDiscovery.Parse(root, "test/model-canonical");

        Assert.NotNull(discovered);
    }

    [Fact]
    public void Returns_null_when_no_entry_matches()
    {
        var root = JsonDocument.Parse($$"""[ {{Entry}} ]""").RootElement;

        Assert.Null(ModelCapabilityDiscovery.Parse(root, "other/model"));
    }

    [Fact]
    public async Task Tolerates_a_non_200_response()
    {
        var factory = new FakeHttpClientFactory(_ => new HttpResponseMessage(HttpStatusCode.InternalServerError));
        var discovery = new ModelCapabilityDiscovery(factory, NullLogger<ModelCapabilityDiscovery>.Instance);

        var result = await discovery.DiscoverAsync(
            ChatModelTestHelpers.Definition(provider: ModelProvider.OpenRouter, discoverCapabilities: true),
            CancellationToken.None);

        Assert.Null(result);
    }

    [Fact]
    public async Task Caches_discovery_results()
    {
        var factory = new FakeHttpClientFactory(_ => new HttpResponseMessage(HttpStatusCode.OK)
        {
            Content = new StringContent($$"""{ "data": [ {{Entry}} ] }"""),
        });
        var discovery = new ModelCapabilityDiscovery(factory, NullLogger<ModelCapabilityDiscovery>.Instance);
        var definition = ChatModelTestHelpers.Definition(provider: ModelProvider.OpenRouter, discoverCapabilities: true);

        await discovery.DiscoverAsync(definition, CancellationToken.None);
        await discovery.DiscoverAsync(definition, CancellationToken.None);

        Assert.Single(factory.Requests);
    }
}
