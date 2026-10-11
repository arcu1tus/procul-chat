namespace Procul.Api.Tests.Support;

/// <summary>
/// An <see cref="IHttpClientFactory"/> backed by a fixed responder, so capability-discovery tests
/// never touch the network.
/// </summary>
internal sealed class FakeHttpClientFactory(Func<HttpRequestMessage, HttpResponseMessage> responder)
    : IHttpClientFactory
{
    /// <summary>The requests the factory's clients have sent.</summary>
    public List<HttpRequestMessage> Requests { get; } = [];

    public HttpClient CreateClient(string name) => new(new Handler(this, responder));

    private sealed class Handler(
        FakeHttpClientFactory owner,
        Func<HttpRequestMessage, HttpResponseMessage> responder) : HttpMessageHandler
    {
        protected override Task<HttpResponseMessage> SendAsync(
            HttpRequestMessage request,
            CancellationToken cancellationToken)
        {
            owner.Requests.Add(request);
            return Task.FromResult(responder(request));
        }
    }
}
