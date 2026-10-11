using Microsoft.Extensions.AI;

namespace Procul.Api.Tests.Support;

/// <summary>
/// A minimal <see cref="IChatClient"/> for tests. It answers <see cref="GetResponseAsync"/> with a
/// canned reply (or a caller-supplied handler) and never touches the network. Streaming is not
/// implemented because the tests that use it exercise the non-streaming title call only.
/// </summary>
internal sealed class FakeChatClient : IChatClient
{
    private readonly Func<IEnumerable<ChatMessage>, ChatOptions?, CancellationToken, Task<ChatResponse>> _handler;

    /// <summary>Replies with <paramref name="response"/> to every request.</summary>
    public FakeChatClient(string response)
        : this((_, _, _) => Task.FromResult(new ChatResponse(new ChatMessage(ChatRole.Assistant, response))))
    {
    }

    /// <summary>Replies using a custom handler, e.g. to throw or capture the request.</summary>
    public FakeChatClient(
        Func<IEnumerable<ChatMessage>, ChatOptions?, CancellationToken, Task<ChatResponse>> handler)
        => _handler = handler;

    public Task<ChatResponse> GetResponseAsync(
        IEnumerable<ChatMessage> messages,
        ChatOptions? options = null,
        CancellationToken cancellationToken = default)
        => _handler(messages, options, cancellationToken);

    public IAsyncEnumerable<ChatResponseUpdate> GetStreamingResponseAsync(
        IEnumerable<ChatMessage> messages,
        ChatOptions? options = null,
        CancellationToken cancellationToken = default)
        => throw new NotSupportedException("Streaming is not used by these tests.");

    public object? GetService(Type serviceType, object? serviceKey = null) => null;

    public void Dispose()
    {
    }
}
