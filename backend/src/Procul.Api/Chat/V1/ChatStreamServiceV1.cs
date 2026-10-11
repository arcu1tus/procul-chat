using System.Runtime.CompilerServices;
using System.Text;
using System.Text.Json;
using System.Text.RegularExpressions;
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
internal sealed class ChatStreamServiceV1(ProculDbContext db, IChatClient chatClient, ILogger<ChatStreamServiceV1> logger)
{
    /// <summary>Upper bound on the generated title length (characters).</summary>
    public const int MaxTitleLength = 60;

    /// <summary>Upper bound on the fallback title derived from the first message.</summary>
    private const int FallbackTitleLength = 50;

    /// <summary>How long we are willing to wait for the title model call.</summary>
    private static readonly TimeSpan TitleTimeout = TimeSpan.FromSeconds(8);

    /// <summary>
    /// System prompt for the title model. Kept tiny: the call is capped at
    /// <see cref="TitleOptions"/> tokens and only ever sees the first user message.
    /// Written as strict, example-driven instructions because the title call may run on a
    /// small or reasoning-heavy model that otherwise restates the task.
    /// </summary>
    private const string TitleSystemPrompt = """
        You write short titles for chat conversations. Given the first message of a
        chat, output a title of at most 5 words. Output the title text only.

        Rules:
        - No quotes, no leading "Title:", no trailing punctuation.
        - Never explain, never repeat these instructions, never describe the message.
        - Use the same language as the message.

        Examples:
        What is the capital of France? -> France's capital
        Help me debug this Python error -> Debugging a Python error
        """;

    private static ChatOptions TitleOptions => new()
    {
        // The configured model is a reasoning model that spends tokens thinking before it
        // emits the title, so the cap must leave room for that. It is still a hard bound:
        // the call can never produce more than this many output tokens, and the prompt is
        // just the system instruction plus the first user message.
        MaxOutputTokens = 300,
        Temperature = 0.2f,
    };

    /// <summary>Upper bound on the number of words a generated title may contain.</summary>
    private const int MaxTitleWords = 8;

    /// <summary>
    /// Phrases that betray a model that ignored the "title only" instruction. A title
    /// containing any of these is rejected and the fallback is used instead.
    /// </summary>
    private static readonly string[] TitleMetaPhrases =
    [
        "the user is",
        "user is asking",
        "user wants",
        "user asked",
        "asking for a",
        "conversation about",
        "chat about",
        "title for",
        "here is a title",
        "here's a title",
        "i cannot",
        "i can't",
        "as an ai",
    ];

    /// <summary>
    /// Streams a brand-new conversation: emits <c>created</c>, streams the assistant's first
    /// reply, then emits the model-generated <c>title</c>. The title call runs concurrently
    /// with the reply, but its DB write happens after the stream, so the injected
    /// <see cref="ProculDbContext"/> is never used from two places at once.
    /// </summary>
    public async IAsyncEnumerable<ChatStreamEventV1> StreamNewConversationAsync(
        Conversation conversation,
        string initialMessage,
        [EnumeratorCancellation] CancellationToken ct
    )
    {
        yield return new ChatStreamEventV1.Created(new ChatStreamCreatedV1(
            new ConversationV1(conversation.Id, conversation.Title, conversation.CreatedAt, conversation.UpdatedAt)
        ));

        var titleTask = GenerateTitleAsync(initialMessage, ct);

        await foreach (var streamEvent in StreamAssistantReplyAsync(conversation.Id, initialMessage, ct))
        {
            yield return streamEvent;
        }

        var title = await titleTask ?? FallbackTitle(initialMessage);
        conversation.Title = title;
        await db.SaveChangesAsync(ct);

        yield return new ChatStreamEventV1.Title(new ChatStreamTitleV1(conversation.Id, title));
    }

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

        // Bump the conversation's activity timestamp so it floats to the top of the list.
        var now = DateTimeOffset.UtcNow;
        await db.Conversations
            .Where(c => c.Id == conversationId)
            .ExecuteUpdateAsync(s => s.SetProperty(c => c.UpdatedAt, now), ct);

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

    /// <summary>
    /// Asks the model for a short title for a brand-new conversation. Purely a model call:
    /// it does not touch the <see cref="ProculDbContext"/>, so it can safely run
    /// concurrently with <see cref="StreamAssistantReplyAsync"/> on the same request.
    /// Returns null when the call fails or times out (the caller falls back).
    /// </summary>
    public async Task<string?> GenerateTitleAsync(string initialMessage, CancellationToken ct)
    {
        try
        {
            using var timeoutCts = CancellationTokenSource.CreateLinkedTokenSource(ct);
            timeoutCts.CancelAfter(TitleTimeout);

            var messages = new List<ChatMessage>
            {
                new(ChatRole.System, TitleSystemPrompt),
                new(ChatRole.User, $"First message: {initialMessage}\n\nTitle:"),
            };

            var response = await chatClient.GetResponseAsync(messages, TitleOptions, timeoutCts.Token);
            logger.LogDebug("Title model output: {RawTitle}", Truncate(response.Text, 600));
            var title = SanitizeTitle(response.Text);
            if (title is null)
            {
                logger.LogWarning("Title generation produced unusable output: {RawTitle}", Truncate(response.Text, 200));
            }

            return title;
        }
        catch (Exception ex)
        {
            // A failed title is never fatal: the caller uses FallbackTitle instead.
            logger.LogWarning(ex, "Title generation failed; falling back to the first message.");
            return null;
        }
    }

    /// <summary>
    /// A reasonable title when the model call is unavailable: the first line of the
    /// user's message, truncated.
    /// </summary>
    public static string FallbackTitle(string initialMessage)
    {
        var text = initialMessage.Trim();
        var newline = text.IndexOf('\n');
        if (newline >= 0)
        {
            text = text[..newline].Trim();
        }

        if (text.Length > FallbackTitleLength)
        {
            text = text[..FallbackTitleLength].TrimEnd() + "…";
        }

        return string.IsNullOrWhiteSpace(text) ? "New Conversation" : text;
    }

    private static string Truncate(string? value, int max) =>
        string.IsNullOrEmpty(value) ? string.Empty : value.Length <= max ? value : value[..max];

    /// <summary>Normalizes raw model output into a single tidy line, or null if unusable.</summary>
    private static string? SanitizeTitle(string? raw)
    {
        if (string.IsNullOrWhiteSpace(raw))
        {
            return null;
        }

        var title = raw.Trim();

        // Keep only the first line; models occasionally add a trailing explanation.
        var newline = title.IndexOfAny(['\n', '\r']);
        if (newline >= 0)
        {
            title = title[..newline];
        }

        title = title.Trim().Trim('"', '\'', '\u201C', '\u201D', '\u2018', '\u2019');

        // Strip a leading "Title:" the model may have echoed.
        title = Regex.Replace(title, @"^\s*title\s*[:\-]\s*", "", RegexOptions.IgnoreCase);

        title = Regex.Replace(title, @"\s+", " ").Trim();

        // Reject explanations / instruction restatements that slipped through.
        var lowered = title.ToLowerInvariant();
        if (TitleMetaPhrases.Any(lowered.Contains))
        {
            return null;
        }

        // A real title is a handful of words; anything longer is a failed generation.
        if (title.Split(' ', StringSplitOptions.RemoveEmptyEntries).Length > MaxTitleWords)
        {
            return null;
        }

        if (title.Length > MaxTitleLength)
        {
            title = title[..MaxTitleLength].TrimEnd();
        }

        title = title.TrimEnd('.', ':', ';', ',', '!', '?', ' ');

        return string.IsNullOrWhiteSpace(title) ? null : title;
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
