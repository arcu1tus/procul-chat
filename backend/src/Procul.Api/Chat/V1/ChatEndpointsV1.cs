using System.Net.ServerSentEvents;
using Microsoft.AspNetCore.Http.HttpResults;
using Microsoft.EntityFrameworkCore;
using Procul.Api.Attachments;
using Procul.Api.Attachments.V1;
using Procul.Api.Chat.Models;
using Procul.Api.Infrastructure;
using Procul.Api.Configuration;

namespace Procul.Api.Chat.V1;

internal static class ChatEndpointsV1
{
    public static RouteGroupBuilder MapChatV1(this RouteGroupBuilder group)
    {
        group.MapGet("/", GetConversationsAsync);
        group.MapPost("/", CreateConversationAsync);
        group.MapGet("/{conversationId:guid}", GetConversationAsync);
        group.MapPatch("/{conversationId:guid}", RenameConversationAsync);
        group.MapDelete("/{conversationId:guid}", DeleteConversationAsync);
        group.MapPut("/{conversationId:guid}/model", SetConversationModelAsync);
        group.MapGet("/{conversationId:guid}/messages", GetConversationMessagesAsync);
        group.MapPost("/{conversationId:guid}/messages", SendMessageAsync);
        group.MapPost("/{conversationId:guid}/messages/{messageId:guid}/edit", EditMessageAsync);
        return group;
    }

    /// <summary>Upper bound on a user message's text length (64 KiB, matching common model limits).</summary>
    internal const int MaxMessageLength = 64 * 1024;

    /// <summary>
    /// The user-facing problem with a message text, or null when it is valid. Rejects empty
    /// (after trim) and oversized text; <paramref name="field"/> names the JSON field.
    /// </summary>
    private static string? ValidateMessageText(string? text, string field, bool hasAttachments = false)
    {
        if (string.IsNullOrWhiteSpace(text) && !hasAttachments)
        {
            return $"'{field}' must not be empty.";
        }

        if (text?.Length > MaxMessageLength)
        {
            return $"'{field}' must be at most {MaxMessageLength} characters.";
        }

        return null;
    }

    /// <summary>
    /// The <c>409 Conflict</c> returned when a client's <c>expectedRevision</c> is stale. The detail
    /// names the current revision so the client can refresh and retry.
    /// </summary>
    private static ProblemHttpResult RevisionConflict(int currentRevision) =>
        TypedResults.Problem(
            statusCode: StatusCodes.Status409Conflict,
            title: "Revision conflict",
            detail: $"The conversation was modified by another client (current revision {currentRevision}). " +
                    "Refresh and retry.");

    private static async Task<Ok<GetConversationsResponseV1>> GetConversationsAsync(
        ProculDbContext db,
        CancellationToken ct
    )
    {
        var conversations = await db.Conversations
            .OrderByDescending(c => c.UpdatedAt)
            .ThenByDescending(c => c.Id)
            .Select(c => new ConversationV1(c.Id, c.Title, c.CreatedAt, c.UpdatedAt, c.Model, c.Revision))
            .ToListAsync(ct);

        return TypedResults.Ok(new GetConversationsResponseV1(conversations));
    }

    private static async Task<Results<ServerSentEventsResult<ChatStreamEventV1>, ProblemHttpResult>> CreateConversationAsync(
        ProculDbContext db,
        ChatStreamServiceV1 chat,
        ChatModelRegistry registry,
        ModelCatalogService catalog,
        AttachmentOptions attachmentOptions,
        CreateConversationRequestV1 body,
        CancellationToken ct
    )
    {
        var model = (body.Model ?? string.Empty).Trim();
        if (model.Length > 0 && registry.Get(model) is null)
        {
            return TypedResults.Problem(
                statusCode: StatusCodes.Status400BadRequest,
                detail: $"Unknown model '{model}'. Use GET /v1/models to list configured models.");
        }

        if (ValidateMessageText(body.InitialMessage, "initialMessage", body.AttachmentIds is { Count: > 0 }) is { } textProblem)
        {
            return TypedResults.Problem(statusCode: StatusCodes.Status400BadRequest, detail: textProblem);
        }

        var slug = model.Length > 0 ? model : null;
        var accepted = ResolvedChatModel.Resolve(registry, catalog, slug);
        var gate = await AttachmentGate.ResolveAsync(db, registry, catalog, body.AttachmentIds, slug, ct,
            maxAttachments: attachmentOptions.MaxAttachmentsPerMessage, model: accepted);
        if (!gate.IsValid)
        {
            return TypedResults.Problem(statusCode: StatusCodes.Status400BadRequest, detail: gate.Error);
        }

        var capabilities = accepted.Input;

        var conversation = new Conversation
        {
            Title = ChatStreamServiceV1.FallbackTitle(string.IsNullOrWhiteSpace(body.InitialMessage)
                ? string.Join(", ", gate.Attachments.Select(a => a.FileName)) : body.InitialMessage),
            Model = slug,
        };
        db.Conversations.Add(conversation);
        await db.SaveChangesAsync(ct);

        return TypedResults.ServerSentEvents(
            chat.StreamNewConversationAsync(conversation, body.InitialMessage ?? "", gate.Attachments, capabilities, ct, accepted.Definition)
        );
    }

    private static async Task<Results<Ok<GetConversationResponseV1>, NotFound>> GetConversationAsync(
        Guid conversationId,
        ProculDbContext db,
        CancellationToken ct
    )
    {
        var conversation = await db.Conversations
            .Where(c => c.Id == conversationId)
            .Select(c => new ConversationV1(c.Id, c.Title, c.CreatedAt, c.UpdatedAt, c.Model, c.Revision))
            .FirstOrDefaultAsync(ct);

        if (conversation is null)
        {
            return TypedResults.NotFound();
        }

        return TypedResults.Ok(new GetConversationResponseV1(conversation));
    }

    private static async Task<Results<Ok<GetConversationResponseV1>, NotFound, ProblemHttpResult>> RenameConversationAsync(
        Guid conversationId,
        ProculDbContext db,
        RenameConversationRequestV1 body,
        CancellationToken ct
    )
    {
        var title = (body.Title ?? string.Empty).Trim();
        if (title.Length is 0 or > ChatStreamServiceV1.MaxTitleLength)
        {
            return TypedResults.Problem(
                statusCode: StatusCodes.Status400BadRequest,
                detail: $"'title' must be between 1 and {ChatStreamServiceV1.MaxTitleLength} characters"
            );
        }

        var conversation = await db.Conversations.FirstOrDefaultAsync(c => c.Id == conversationId, ct);
        if (conversation is null)
        {
            return TypedResults.NotFound();
        }

        if (body.ExpectedRevision is { } expected && expected != conversation.Revision)
        {
            return RevisionConflict(conversation.Revision);
        }

        conversation.Title = title;
        conversation.Revision++;
        await db.SaveChangesAsync(ct);

        return TypedResults.Ok(new GetConversationResponseV1(
            new ConversationV1(conversation.Id, conversation.Title, conversation.CreatedAt, conversation.UpdatedAt, conversation.Model, conversation.Revision)
        ));
    }

    private static async Task<Results<Ok<GetConversationResponseV1>, NotFound, ProblemHttpResult>> SetConversationModelAsync(
        Guid conversationId,
        ProculDbContext db,
        ChatModelRegistry registry,
        SetConversationModelRequestV1 body,
        CancellationToken ct
    )
    {
        var model = (body.Model ?? string.Empty).Trim();
        if (model.Length == 0 || registry.Get(model) is null)
        {
            return TypedResults.Problem(
                statusCode: StatusCodes.Status400BadRequest,
                detail: $"Unknown model '{body.Model}'. Use GET /v1/models to list configured models.");
        }

        var conversation = await db.Conversations.FirstOrDefaultAsync(c => c.Id == conversationId, ct);
        if (conversation is null)
        {
            return TypedResults.NotFound();
        }

        if (body.ExpectedRevision is { } expected && expected != conversation.Revision)
        {
            return RevisionConflict(conversation.Revision);
        }

        conversation.Model = model;
        conversation.Revision++;
        await db.SaveChangesAsync(ct);

        return TypedResults.Ok(new GetConversationResponseV1(
            new ConversationV1(conversation.Id, conversation.Title, conversation.CreatedAt, conversation.UpdatedAt, conversation.Model, conversation.Revision)
        ));
    }

    private static async Task<Results<NoContent, NotFound>> DeleteConversationAsync(
        Guid conversationId,
        ProculDbContext db,
        IAttachmentStore attachmentStore,
        CancellationToken ct
    )
    {
        var conversation = await db.Conversations.FirstOrDefaultAsync(c => c.Id == conversationId, ct);
        if (conversation is null)
        {
            return TypedResults.NotFound();
        }

        // Messages (and their attachment metadata + Postgres blobs) are removed by the cascade,
        // but the bytes in the configured store are not — delete them first.
        var attachments = await db.ConversationMessages
            .Where(m => m.ConversationId == conversationId)
            .SelectMany(m => m.Attachments)
            .ToListAsync(ct);
        await attachmentStore.DeleteBytesAsync(attachments, ct);

        db.Conversations.Remove(conversation);
        await db.SaveChangesAsync(ct);

        return TypedResults.NoContent();
    }

    private static async Task<Results<Ok<GetConversationMessagesResponseV1>, ProblemHttpResult>> GetConversationMessagesAsync(
        Guid conversationId,
        ProculDbContext db,
        CancellationToken ct,

        int limit = 20,
        Guid? afterMessageId = null
    )
    {
        if (limit is > 100 or < 1)
        {
            return TypedResults.Problem(
                statusCode: StatusCodes.Status400BadRequest,
                detail: "'limit' field out of range [1-100]"
            );
        }

        var conversationExists = await db.Conversations.AnyAsync(c => c.Id == conversationId, ct);
        if (!conversationExists)
        {
            return TypedResults.Problem(
                statusCode: StatusCodes.Status404NotFound,
                detail: "the conversation with the given ID was not found"
            );
        }

        var query = db.ConversationMessages.Where(m => m.ConversationId == conversationId);

        if (afterMessageId is not null)
        {
            var cursor = await db.ConversationMessages
                .Where(m => m.Id == afterMessageId && m.ConversationId == conversationId)
                .Select(m => new { m.CreatedAt, m.Id })
                .FirstOrDefaultAsync(ct);

            if (cursor is null)
            {
                return TypedResults.Problem(
                    statusCode: StatusCodes.Status404NotFound,
                    detail: "the message with the afterMessageId was not found"
                );
            }

            query = query.Where(m =>
                m.CreatedAt < cursor.CreatedAt
                || (m.CreatedAt == cursor.CreatedAt && m.Id.CompareTo(cursor.Id) < 0)
            );
        }

        var messageRows = await query
            .OrderByDescending(m => m.CreatedAt)
            .ThenByDescending(m => m.Id)
            .Take(limit)
            .Select(m => new
            {
                m.Id,
                m.Text,
                m.MessageRole,
                m.CreatedAt,
                m.Reasoning,
                m.CompletionStatus,
                m.Model,
                ToolCalls = m.ToolCalls.OrderBy(t => t.Sequence).Select(t => new ConversationToolCallV1(
                    t.CallId, t.Name, t.Arguments, t.Result, t.Error, t.Status)).ToList(),
                Attachments = m.Attachments
                    .Select(a => new AttachmentV1(a.Id, a.FileName, a.ContentType, a.SizeBytes, a.CreatedAt))
                    .ToList(),
            })
            .ToListAsync(ct);

        // Per-response metadata: attach each assistant message's model + token usage.
        var messageIds = messageRows.Select(m => m.Id).ToList();
        var usageByMessage = (await db.TurnUsages
                .Where(u => u.MessageId != null && messageIds.Contains(u.MessageId.Value))
                .ToListAsync(ct))
            .GroupBy(u => u.MessageId!.Value)
            .ToDictionary(group => group.Key, group => group.First());

        var messages = messageRows
            .Select(m =>
            {
                usageByMessage.TryGetValue(m.Id, out var usage);
                return new ConversationMessageV1(
                    Id: m.Id,
                    ConversationId: conversationId,
                    Text: m.Text,
                    MessageRole: m.MessageRole,
                    CreatedAt: m.CreatedAt,
                    Attachments: m.Attachments,
                    Model: m.Model ?? usage?.Model,
                    Usage: usage is null
                        ? null
                        : new ConversationMessageUsageV1(
                            usage.InputTokens,
                            usage.OutputTokens,
                            usage.CachedInputTokens,
                            usage.TotalTokens),
                    ToolCalls: m.ToolCalls,
                    Reasoning: m.Reasoning,
                    CompletionStatus: m.CompletionStatus);
            })
            .ToList();

        return TypedResults.Ok(new GetConversationMessagesResponseV1(messages));
    }

    private static async Task<Results<ServerSentEventsResult<ChatStreamEventV1>, NotFound, ProblemHttpResult>> SendMessageAsync(
        ProculDbContext db,
        ChatStreamServiceV1 chat,
        ChatModelRegistry registry,
        ModelCatalogService catalog,
        AttachmentOptions attachmentOptions,
        Guid conversationId,
        SendMessageRequestV1 body,
        CancellationToken ct
    )
    {
        var conversation = await db.Conversations.FirstOrDefaultAsync(c => c.Id == conversationId, ct);
        if (conversation is null)
        {
            return TypedResults.NotFound();
        }

        if (body.ExpectedRevision is { } expected && expected != conversation.Revision)
        {
            return RevisionConflict(conversation.Revision);
        }

        if (ValidateMessageText(body.Text, "text", body.AttachmentIds is { Count: > 0 }) is { } textProblem)
        {
            return TypedResults.Problem(statusCode: StatusCodes.Status400BadRequest, detail: textProblem);
        }

        var accepted = ResolvedChatModel.Resolve(registry, catalog, conversation.Model);
        var gate = await AttachmentGate.ResolveAsync(db, registry, catalog, body.AttachmentIds, conversation.Model, ct,
            maxAttachments: attachmentOptions.MaxAttachmentsPerMessage, model: accepted);
        if (!gate.IsValid)
        {
            return TypedResults.Problem(statusCode: StatusCodes.Status400BadRequest, detail: gate.Error);
        }

        var capabilities = accepted.Input;

        return TypedResults.ServerSentEvents(
            chat.StreamAssistantReplyAsync(conversationId, body.Text ?? "", gate.Attachments, capabilities, ct, accepted.Definition)
        );
    }

    private static async Task<Results<ServerSentEventsResult<ChatStreamEventV1>, NotFound, ProblemHttpResult>> EditMessageAsync(
        ProculDbContext db,
        ChatStreamServiceV1 chat,
        ChatModelRegistry registry,
        ModelCatalogService catalog,
        AttachmentOptions attachmentOptions,
        Guid conversationId,
        Guid messageId,
        EditMessageRequestV1 body,
        CancellationToken ct
    )
    {
        var conversation = await db.Conversations.FirstOrDefaultAsync(c => c.Id == conversationId, ct);
        if (conversation is null)
        {
            return TypedResults.NotFound();
        }

        if (body.ExpectedRevision is { } expected && expected != conversation.Revision)
        {
            return RevisionConflict(conversation.Revision);
        }

        var message = await db.ConversationMessages
            .Include(m => m.Attachments)
            .FirstOrDefaultAsync(m => m.Id == messageId && m.ConversationId == conversationId, ct);
        if (message is null)
        {
            return TypedResults.NotFound();
        }

        if (message.MessageRole != MessageRole.User)
        {
            return TypedResults.Problem(
                statusCode: StatusCodes.Status400BadRequest,
                detail: "Only user messages can be edited.");
        }

        var effectiveIds = body.AttachmentIds ?? message.Attachments.Select(a => a.Id).ToList();
        if (ValidateMessageText(body.Text, "text", effectiveIds.Count > 0) is { } textProblem)
        {
            return TypedResults.Problem(statusCode: StatusCodes.Status400BadRequest, detail: textProblem);
        }
        var accepted = ResolvedChatModel.Resolve(registry, catalog, conversation.Model);
        var gate = await AttachmentGate.ResolveAsync(db, registry, catalog, effectiveIds, conversation.Model, ct,
            allowMessageId: messageId, maxAttachments: attachmentOptions.MaxAttachmentsPerMessage, model: accepted);
        if (!gate.IsValid)
        {
            return TypedResults.Problem(statusCode: StatusCodes.Status400BadRequest, detail: gate.Error);
        }
        IReadOnlyList<Attachment>? replacement = body.AttachmentIds is null ? null : gate.Attachments;
        var capabilities = accepted.Input;

        return TypedResults.ServerSentEvents(
            chat.EditMessageAsync(conversationId, messageId, body.Text ?? "", replacement, capabilities, ct, accepted.Definition)
        );
    }
}
