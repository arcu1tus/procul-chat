using Microsoft.Extensions.AI;

namespace Procul.Api.Tests.Support;

/// <summary>
/// A counting <see cref="IChatClient"/> for catalog/health tests. It answers
/// <see cref="GetResponseAsync"/> with a canned reply (or throws) and records how many times it
/// was called, so tests can assert whether a model was probed.
/// </summary>
internal sealed class RecordingChatClient(string response = "alive") : IChatClient
{
    private int _responseCalls;

    /// <summary>How many times <see cref="GetResponseAsync"/> has been called.</summary>
    public int ResponseCallCount => Volatile.Read(ref _responseCalls);

    /// <summary>When set, <see cref="GetResponseAsync"/> throws this instead of replying.</summary>
    public Exception? ThrowOnCall { get; init; }

    public Task<ChatResponse> GetResponseAsync(
        IEnumerable<ChatMessage> messages,
        ChatOptions? options = null,
        CancellationToken cancellationToken = default)
    {
        Interlocked.Increment(ref _responseCalls);

        return ThrowOnCall is not null
            ? Task.FromException<ChatResponse>(ThrowOnCall)
            : Task.FromResult(new ChatResponse(new ChatMessage(ChatRole.Assistant, response)));
    }

    public IAsyncEnumerable<ChatResponseUpdate> GetStreamingResponseAsync(
        IEnumerable<ChatMessage> messages,
        ChatOptions? options = null,
        CancellationToken cancellationToken = default) =>
        throw new NotSupportedException("RecordingChatClient does not stream.");

    public object? GetService(Type serviceType, object? serviceKey = null) => null;

    public void Dispose()
    {
    }
}
