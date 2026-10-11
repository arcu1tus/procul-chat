using Microsoft.Extensions.AI;

namespace Procul.Api.Tests.Support;

/// <summary>
/// A minimal <see cref="IChatClient"/> for tests. It answers <see cref="GetResponseAsync"/> with a
/// canned reply (or a caller-supplied handler) and never touches the network. A streaming handler
/// can be supplied for tests that exercise the SSE reply path.
/// </summary>
internal sealed class FakeChatClient : IChatClient
{
    private readonly Func<IEnumerable<ChatMessage>, ChatOptions?, CancellationToken, Task<ChatResponse>> _handler;
    private readonly Func<IEnumerable<ChatMessage>, ChatOptions?, CancellationToken, IAsyncEnumerable<ChatResponseUpdate>>? _streamHandler;

    /// <summary>Replies with <paramref name="response"/> to every request.</summary>
    public FakeChatClient(string response)
        : this((_, _, _) => Task.FromResult(new ChatResponse(new ChatMessage(ChatRole.Assistant, response))))
    {
    }

    /// <summary>Replies using a custom handler, e.g. to throw or capture the request.</summary>
    public FakeChatClient(
        Func<IEnumerable<ChatMessage>, ChatOptions?, CancellationToken, Task<ChatResponse>> handler,
        Func<IEnumerable<ChatMessage>, ChatOptions?, CancellationToken, IAsyncEnumerable<ChatResponseUpdate>>? streamHandler = null)
    {
        _handler = handler;
        _streamHandler = streamHandler;
    }

    public Task<ChatResponse> GetResponseAsync(
        IEnumerable<ChatMessage> messages,
        ChatOptions? options = null,
        CancellationToken cancellationToken = default)
        => _handler(messages, options, cancellationToken);

    public IAsyncEnumerable<ChatResponseUpdate> GetStreamingResponseAsync(
        IEnumerable<ChatMessage> messages,
        ChatOptions? options = null,
        CancellationToken cancellationToken = default)
        => _streamHandler?.Invoke(messages, options, cancellationToken)
            ?? throw new NotSupportedException("This FakeChatClient was built without a streaming handler.");

    public object? GetService(Type serviceType, object? serviceKey = null) => null;

    public void Dispose()
    {
    }
}
