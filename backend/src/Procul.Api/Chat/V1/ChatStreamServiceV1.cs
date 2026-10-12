using System.Runtime.CompilerServices;
using System.Text;
using System.Text.Json;
using System.Text.RegularExpressions;
using Microsoft.EntityFrameworkCore;
using Microsoft.Extensions.AI;
using Procul.Api.Attachments;
using Procul.Api.Chat.Models;
using Procul.Api.Chat.Tools;
using Procul.Api.Configuration;
using Procul.Api.Infrastructure;
using Procul.Api.Mcp;

namespace Procul.Api.Chat.V1;

/// <summary>
/// Shared logic for a single conversation turn: persists the user message, streams the
/// assistant's reply from the conversation's selected model, persists that reply, and emits the
/// events both the "create conversation" and "send message" endpoints stream to the client.
/// </summary>
internal sealed class ChatStreamServiceV1(
    ProculDbContext db,
    ChatModelRegistry registry,
    ModelUsageTracker usageTracker,
    ProculConfig config,
    McpClientManager mcp,
    IAttachmentStore attachmentStore,
    AttachmentOptions attachmentOptions,
    TurnToolFactory toolFactory,
    ILogger<ChatStreamServiceV1> logger)
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
        chat, output a title of at most 8 words. Output the title text only.

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

    /// <summary>
    /// Upper bound on the number of words a generated title may contain. The prompt asks the
    /// model for at most this many; a longer result is treated as a failed generation and the
    /// caller falls back to <see cref="FallbackTitle"/>.
    /// </summary>
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
        IReadOnlyList<Attachment> attachments,
        IReadOnlySet<ModelInputModality> capabilities,
        [EnumeratorCancellation] CancellationToken ct
    )
    {
        yield return new ChatStreamEventV1.Created(new ChatStreamCreatedV1(
            new ConversationV1(conversation.Id, conversation.Title, conversation.CreatedAt, conversation.UpdatedAt, conversation.Model, conversation.Revision)
        ));

        var titleDefinition = ResolveTitleModel(conversation.Model);
        var titleTask = GenerateTitleAsync(titleDefinition, initialMessage, ct);

        await foreach (var streamEvent in StreamAssistantReplyAsync(conversation.Id, initialMessage, attachments, capabilities, ct))
        {
            yield return streamEvent;
        }

        // The title call runs concurrently with the reply, but its usage write happens here,
        // after the reply's write, so the injected DbContext is never used from two places.
        var titleResult = await titleTask;
        conversation.Title = titleResult.Title ?? FallbackTitle(initialMessage);
        if (titleResult.Usage.HasUsage)
        {
            db.TurnUsages.Add(titleResult.Usage.ToTurnUsage(conversation.Id, titleDefinition.Slug, TurnKind.Title));
        }

        await db.SaveChangesAsync(ct);

        yield return new ChatStreamEventV1.Title(new ChatStreamTitleV1(conversation.Id, conversation.Title));
    }

    /// <summary>
    /// Persists a new user message (with its attachments), then streams the assistant's reply.
    /// Shared by the create and send endpoints; the reply core is <see cref="StreamReplyAsync"/>.
    /// </summary>
    public async IAsyncEnumerable<ChatStreamEventV1> StreamAssistantReplyAsync(
        Guid conversationId,
        string userText,
        IReadOnlyList<Attachment> attachments,
        IReadOnlySet<ModelInputModality> capabilities,
        [EnumeratorCancellation] CancellationToken ct
    )
    {
        var userMessage = new ConversationMessage
        {
            ConversationId = conversationId,
            Text = userText,
            MessageRole = MessageRole.User
        };

        // Attach the uploaded files to the persisted user message; the Postgres blob rows and the
        // metadata both live in this context, so one save persists everything.
        foreach (var attachment in attachments)
        {
            attachment.ConversationId = conversationId;
            attachment.MessageId = userMessage.Id;
            userMessage.Attachments.Add(attachment);
        }

        db.ConversationMessages.Add(userMessage);

        // Bump the conversation's activity timestamp so it floats to the top of the list. Mutating
        // the tracked entity (rather than ExecuteUpdateAsync) keeps the in-memory provider happy.
        var conversation = await db.Conversations.FirstOrDefaultAsync(c => c.Id == conversationId, ct);
        if (conversation is not null)
        {
            conversation.UpdatedAt = DateTimeOffset.UtcNow;
            conversation.Revision++;
        }

        await db.SaveChangesAsync(ct);

        await foreach (var streamEvent in StreamReplyAsync(conversationId, userMessage, capabilities, ct))
        {
            yield return streamEvent;
        }
    }

    /// <summary>
    /// Edits an existing user message: truncates every message after it (deleting their attachment
    /// bytes), drops their usage rows, rewrites the text, optionally replaces the attachments, and
    /// re-prompts the model. Editing is **destructive in v1** — see the future-branching note in the
    /// docs.
    /// </summary>
    public async IAsyncEnumerable<ChatStreamEventV1> EditMessageAsync(
        Guid conversationId,
        Guid messageId,
        string newText,
        IReadOnlyList<Attachment>? replacementAttachments,
        IReadOnlySet<ModelInputModality> capabilities,
        [EnumeratorCancellation] CancellationToken ct
    )
    {
        var message = await db.ConversationMessages
            .Include(m => m.Attachments)
            .FirstOrDefaultAsync(m => m.Id == messageId && m.ConversationId == conversationId, ct);

        if (message is null)
        {
            // The endpoint validates existence/role before streaming; guard direct callers.
            yield return new ChatStreamEventV1.Failed(new(Error: "The message was not found."));
            yield break;
        }

        // 1. Truncate every message after the edited one, using the same (CreatedAt, Id) keyset
        //    order the history uses. Delete the bytes *before* the rows: metadata and Postgres
        //    blobs cascade, but S3 objects do not.
        var discarded = await db.ConversationMessages
            .Where(m => m.ConversationId == conversationId
                && (m.CreatedAt > message.CreatedAt
                    || (m.CreatedAt == message.CreatedAt && m.Id.CompareTo(message.Id) > 0)))
            .Include(m => m.Attachments)
            .ToListAsync(ct);

        await attachmentStore.DeleteBytesAsync(discarded.SelectMany(m => m.Attachments), ct);
        db.ConversationMessages.RemoveRange(discarded);

        // 2. Drop the discarded turns' usage rows so the counter matches the visible branch. The
        //    edited turn's reply row is included (it is created after the user message) and is
        //    replaced by the new reply's row.
        var discardedUsage = await db.TurnUsages
            .Where(u => u.ConversationId == conversationId && u.CreatedAt > message.CreatedAt)
            .ToListAsync(ct);
        db.TurnUsages.RemoveRange(discardedUsage);

        // 3. Rewrite the edited message.
        message.Text = newText;

        // 4. Reconcile attachments when the client supplied a replacement set (null = keep current).
        if (replacementAttachments is not null)
        {
            await ApplyReplacementAttachmentsAsync(message, conversationId, replacementAttachments, ct);
        }

        var conversation = await db.Conversations.FirstOrDefaultAsync(c => c.Id == conversationId, ct);
        if (conversation is not null)
        {
            conversation.UpdatedAt = DateTimeOffset.UtcNow;
            conversation.Revision++;
        }

        await db.SaveChangesAsync(ct);

        await foreach (var streamEvent in StreamReplyAsync(conversationId, message, capabilities, ct))
        {
            yield return streamEvent;
        }
    }

    /// <summary>
    /// Reconciles a message's attachments against a replacement set: removes (bytes + metadata)
    /// any not in the set, attaches the new ones, and applies the client's order. The set's items
    /// are already validated and tracked by <see cref="AttachmentGate"/>.
    /// </summary>
    private async Task ApplyReplacementAttachmentsAsync(
        ConversationMessage message,
        Guid conversationId,
        IReadOnlyList<Attachment> replacement,
        CancellationToken ct)
    {
        var keepIds = replacement.Select(a => a.Id).ToHashSet();

        var removed = message.Attachments.Where(a => !keepIds.Contains(a.Id)).ToList();
        await attachmentStore.DeleteBytesAsync(removed, ct);
        foreach (var attachment in removed)
        {
            message.Attachments.Remove(attachment);
            db.Attachments.Remove(attachment);
        }

        var ordered = new List<Attachment>(replacement.Count);
        foreach (var attachment in replacement)
        {
            var existing = message.Attachments.FirstOrDefault(a => a.Id == attachment.Id);
            if (existing is not null)
            {
                ordered.Add(existing);
                continue;
            }

            attachment.ConversationId = conversationId;
            attachment.MessageId = message.Id;
            ordered.Add(attachment);
        }

        // Preserve the client's order for this turn.
        message.Attachments.Clear();
        message.Attachments.AddRange(ordered);
    }

    /// <summary>
    /// The reply core: given an already-persisted <paramref name="userMessage"/>, loads history,
    /// resolves the conversation's model, streams the reply, and persists the assistant message
    /// plus its usage. The edited message and the last message of a send both flow through here.
    /// </summary>
    private async IAsyncEnumerable<ChatStreamEventV1> StreamReplyAsync(
        Guid conversationId,
        ConversationMessage userMessage,
        IReadOnlySet<ModelInputModality> capabilities,
        [EnumeratorCancellation] CancellationToken ct
    )
    {
        // The conversation remembers its model; an unknown/stale slug falls back to the default.
        var conversation = await db.Conversations.FirstOrDefaultAsync(c => c.Id == conversationId, ct);
        var definition = registry.ResolveOrDefault(conversation?.Model);
        var chatClient = registry.GetClient(definition.Slug);

        yield return new ChatStreamEventV1.Processing(new(Message: "received"));

        var history = await db.ConversationMessages
            .Where(m => m.ConversationId == conversationId)
            .Include(m => m.Attachments)
            .OrderBy(m => m.CreatedAt)
            .ThenBy(m => m.Id)
            .ToListAsync(ct);

        var messages = new List<ChatMessage>(history.Count + 1)
        {
            new(ChatRole.System, toolFactory.ComposeSystemPrompt(mcp)),
        };

        foreach (var message in history)
        {
            messages.Add(new ChatMessage(
                role: message.MessageRole.ToChatRole(),
                contents: await BuildMessageContentAsync(
                    message,
                    isCurrentTurn: message.Id == userMessage.Id,
                    capabilities,
                    ct)));
        }

        // Media produced by a tool mid-stream is collected here and linked to the assistant
        // message once the reply is persisted.
        var media = new GeneratedMediaCollector();
        var toolContext = new TurnToolContext(
            db, attachmentStore, attachmentOptions, conversationId, definition.Slug, media);

        var options = new ChatOptions { Tools = toolFactory.BuildTurnTools(toolContext, mcp) };

        var reply = new StringBuilder();
        var failed = false;
        var usage = new TurnUsageTotals();

        await foreach (var streamEvent in CatchToEvent(
            StreamTokens(
                chatClient.GetStreamingResponseAsync(messages, options, ct),
                reply,
                usage,
                media,
                definition.Slug,
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

        var assistantMessage = new ConversationMessage
        {
            ConversationId = conversationId,
            Text = reply.ToString(),
            MessageRole = MessageRole.Assistant
        };
        db.ConversationMessages.Add(assistantMessage);

        // Link the turn's generated/shown images to the reply so they survive a reload.
        foreach (var attachment in media.Attachments)
        {
            attachment.ConversationId = conversationId;
            attachment.MessageId = assistantMessage.Id;
        }

        if (usage.HasUsage)
        {
            var usageRow = usage.ToTurnUsage(conversationId, definition.Slug, TurnKind.Chat);
            usageRow.MessageId = assistantMessage.Id;
            db.TurnUsages.Add(usageRow);
        }

        await db.SaveChangesAsync(ct);
        usageTracker.RecordUse(definition.Slug);

        yield return new ChatStreamEventV1.Done(new());
    }

    /// <summary>
    /// Builds the content parts for one history message. The user's text is always first. Current
    /// attachments carry their bytes; earlier ones do (only when <c>attachments.resendHistory</c>)
    /// or contribute a short note so the model still knows the file existed without re-sending a
    /// large blob every turn.
    /// </summary>
    private async Task<List<AIContent>> BuildMessageContentAsync(
        ConversationMessage message,
        bool isCurrentTurn,
        IReadOnlySet<ModelInputModality> capabilities,
        CancellationToken ct)
    {
        var parts = new List<AIContent> { new TextContent(message.Text) };

        foreach (var attachment in message.Attachments)
        {
            if (!isCurrentTurn && !attachmentOptions.ResendHistory)
            {
                parts.Add(AttachmentContentBuilder.HistoryNote(attachment));
                continue;
            }

            byte[] bytes;
            try
            {
                bytes = await ReadAttachmentAsync(attachment, ct);
            }
            catch (IOException)
            {
                // The bytes are gone (e.g. an S3 object was deleted). Degrade to a note rather
                // than failing the whole turn.
                parts.Add(AttachmentContentBuilder.HistoryNote(attachment));
                continue;
            }

            parts.AddRange(AttachmentContentBuilder.Build(
                attachment, bytes, capabilities, attachmentOptions.TextInlineMaxBytes));
        }

        return parts;
    }

    /// <summary>Reads an attachment's bytes fully into memory (bounded by the upload size cap).</summary>
    private async Task<byte[]> ReadAttachmentAsync(Attachment attachment, CancellationToken ct)
    {
        await using var stream = await attachmentStore.OpenReadAsync(attachment.StorageKey, ct);
        using var buffer = new MemoryStream();
        await stream.CopyToAsync(buffer, ct);
        return buffer.ToArray();
    }

    /// <summary>
    /// Asks the model for a short title for a brand-new conversation. Purely a model call:
    /// it does not touch the <see cref="ProculDbContext"/>, so it can safely run
    /// concurrently with <see cref="StreamAssistantReplyAsync"/> on the same request.
    /// Returns an unusable title (null) when the call fails or times out (the caller falls
    /// back), along with whatever usage the call reported.
    /// </summary>
    public async Task<TitleGenerationResult> GenerateTitleAsync(
        ChatModelDefinition definition,
        string initialMessage,
        CancellationToken ct)
    {
        var usage = new TurnUsageTotals();
        var chatClient = registry.GetClient(definition.Slug);

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
            usage.Add(response.Usage);
            usageTracker.RecordUse(definition.Slug);
            logger.LogDebug("Title model output: {RawTitle}", Truncate(response.Text, 600));
            var title = SanitizeTitle(response.Text);
            if (title is null)
            {
                logger.LogWarning("Title generation produced unusable output: {RawTitle}", Truncate(response.Text, 200));
            }

            return new TitleGenerationResult(title, usage);
        }
        catch (Exception ex)
        {
            // A failed title is never fatal: the caller uses FallbackTitle instead.
            logger.LogWarning(ex, "Title generation failed; falling back to the first message.");
            return new TitleGenerationResult(null, usage);
        }
    }

    /// <summary>
    /// The model used for the title call: <c>titleModel</c> from the config when set, otherwise the
    /// conversation's own model.
    /// </summary>
    private ChatModelDefinition ResolveTitleModel(string? conversationModel) =>
        string.IsNullOrWhiteSpace(config.TitleModel)
            ? registry.ResolveOrDefault(conversationModel)
            : registry.ResolveOrDefault(config.TitleModel);

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

    internal static async IAsyncEnumerable<ChatStreamEventV1> StreamTokens(
        IAsyncEnumerable<ChatResponseUpdate> updates,
        StringBuilder reply,
        TurnUsageTotals usage,
        GeneratedMediaCollector? media,
        string? model,
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

                    // A turn can make several underlying model calls (the tool-invocation
                    // loop); their usage payloads are summed rather than replaced.
                    case UsageContent usageContent:
                        usage.Add(usageContent.Details);
                        break;
                }
            }

            // A media tool ran during this update; surface the image now that the tool finished.
            if (media is not null)
            {
                while (media.TryDequeueEvent(out var imageEvent) && imageEvent is not null)
                {
                    yield return imageEvent;
                }
            }

            if (string.IsNullOrEmpty(update.Text))
            {
                continue;
            }

            reply.Append(update.Text);
            yield return new ChatStreamEventV1.Token(new(Content: update.Text));
        }

        // Drain any images enqueued by a tool whose result landed on the final update.
        if (media is not null)
        {
            while (media.TryDequeueEvent(out var imageEvent) && imageEvent is not null)
            {
                yield return imageEvent;
            }
        }

        // Emit a single usage event once the reply is fully streamed (just before `done`),
        // so the client can add this turn's tokens to the conversation's running total.
        if (usage.HasUsage)
        {
            yield return new ChatStreamEventV1.Usage(new(
                InputTokens: usage.InputTokens,
                OutputTokens: usage.OutputTokens,
                CachedInputTokens: usage.CachedInputTokens,
                TotalTokens: usage.TotalTokens,
                Model: model
            ));
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
