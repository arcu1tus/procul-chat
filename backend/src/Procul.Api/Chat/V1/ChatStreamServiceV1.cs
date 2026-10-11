using System.Runtime.CompilerServices;
using System.Text;
using System.Text.Json;
using Microsoft.EntityFrameworkCore;
using Microsoft.Extensions.AI;
using Procul.Api.Chat.Tools;
using Procul.Api.Infrastructure;

namespace Procul.Api.Chat.V1;

/// <summary>
/// Shared logic for a single conversation turn: persists the user message, streams the
/// assistant's reply from the chat model, persists that reply, and emits the events both
/// the "create conversation" and "send message" endpoints stream to the client.
/// </summary>
internal sealed class ChatStreamServiceV1(ProculDbContext db, IChatClient chatClient)
{
    public async IAsyncEnumerable<ChatStreamEventV1> StreamAssistantReplyAsync(
        Guid conversationId,
        string userText,
        [EnumeratorCancellation] CancellationToken ct
    )
    {
        yield return new ChatStreamEventV1.Processing(new(Message: "received"));

        var history = await db.ConversationMessages
            .Where(m => m.ConversationId == conversationId)
            .OrderBy(m => m.CreatedAt)
            .ThenBy(m => m.Id)
            .Select(m => new ConversationMessageV1(
                Id: m.Id,
                ConversationId: m.ConversationId,
                Text: m.Text,
                MessageRole: m.MessageRole,
                CreatedAt: m.CreatedAt
            ))
            .ToListAsync(ct);

        var userMessage = new ConversationMessage
        {
            ConversationId = conversationId,
            Text = userText,
            MessageRole = MessageRole.User
        };

        db.ConversationMessages.Add(userMessage);
        await db.SaveChangesAsync(ct);

        history.Add(new ConversationMessageV1(
            Id: userMessage.Id,
            ConversationId: userMessage.ConversationId,
            Text: userMessage.Text,
            MessageRole: userMessage.MessageRole,
            CreatedAt: userMessage.CreatedAt
        ));

        var messages = new List<ChatMessage>(history.Count + 1)
        {
            new(ChatRole.System, AgentTools.SystemPrompt),
        };
        messages.AddRange(history.Select(m => new ChatMessage(
            role: m.MessageRole.ToChatRole(),
            content: m.Text
        )));

        var options = new ChatOptions { Tools = [.. AgentTools.All] };

        var reply = new StringBuilder();
        var failed = false;

        await foreach (var streamEvent in CatchToEvent(
            StreamTokens(
                chatClient.GetStreamingResponseAsync(messages, options, ct),
                reply,
                ct
            ),
            ex => new ChatStreamEventV1.Failed(new(Error: ex.Message)),
            ct
        ))
        {
            if (streamEvent is ChatStreamEventV1.Failed)
            {
                failed = true;
            }

            yield return streamEvent;
        }

        if (failed)
        {
            yield break;
        }

        db.ConversationMessages.Add(new ConversationMessage
        {
            ConversationId = conversationId,
            Text = reply.ToString(),
            MessageRole = MessageRole.Assistant
        });
        await db.SaveChangesAsync(ct);

        yield return new ChatStreamEventV1.Done(new());
    }

    private static async IAsyncEnumerable<ChatStreamEventV1> StreamTokens(
        IAsyncEnumerable<ChatResponseUpdate> updates,
        StringBuilder reply,
        [EnumeratorCancellation] CancellationToken ct
    )
    {
        await foreach (var update in updates.WithCancellation(ct))
        {
            // `UseFunctionInvocation()` executes tools internally, but still surfaces the
            // model's call request and the tool's result as content on the updates it yields.
            // Forward them so the client can show tool activity while the reply streams.
            foreach (var content in update.Contents)
            {
                switch (content)
                {
                    case FunctionCallContent call:
                        yield return new ChatStreamEventV1.ToolCall(new(
                            CallId: call.CallId,
                            Name: call.Name,
                            Arguments: FormatArguments(call.Arguments)
                        ));
                        break;

                    case FunctionResultContent result:
                        yield return new ChatStreamEventV1.ToolResult(new(
                            CallId: result.CallId,
                            Result: FormatResult(result.Result),
                            Error: result.Exception?.Message
                        ));
                        break;
                }
            }

            if (string.IsNullOrEmpty(update.Text))
            {
                continue;
            }

            reply.Append(update.Text);
            yield return new ChatStreamEventV1.Token(new(Content: update.Text));
        }
    }

    /// <summary>Serializes tool arguments to a JSON object string, or null when there are none.</summary>
    private static string? FormatArguments(IDictionary<string, object?>? arguments)
        => arguments is { Count: > 0 } ? JsonSerializer.Serialize(arguments) : null;

    /// <summary>Renders a tool result for display: strings pass through, everything else is JSON.</summary>
    private static string? FormatResult(object? result) => result switch
    {
        null => null,
        string text => text,
        // Tool results arrive boxed as JsonElement; unwrap strings so quotes/escapes don't leak.
        JsonElement { ValueKind: JsonValueKind.String } element => element.GetString(),
        JsonElement element => element.GetRawText(),
        _ => JsonSerializer.Serialize(result),
    };

    /// <summary>
    /// Forwards <paramref name="source"/>, converting a mid-stream failure into a single
    /// <paramref name="onError"/> event instead of aborting the response. Cancellation is
    /// always propagated so a disconnected client stops the work.
    /// </summary>
    private static async IAsyncEnumerable<T> CatchToEvent<T>(
        IAsyncEnumerable<T> source,
        Func<Exception, T> onError,
        [EnumeratorCancellation] CancellationToken ct
    )
    {
        await using var enumerator = source.GetAsyncEnumerator(ct);

        while (true)
        {
            T current = default!;
            Exception? error = null;

            try
            {
                if (!await enumerator.MoveNextAsync())
                {
                    yield break;
                }

                current = enumerator.Current;
            }
            catch (OperationCanceledException)
            {
                throw;
            }
            catch (Exception ex)
            {
                error = ex;
            }

            if (error is not null)
            {
                yield return onError(error);
                yield break;
            }

            yield return current;
        }
    }
}
