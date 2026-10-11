using System.Net.ServerSentEvents;
using Microsoft.AspNetCore.Http.HttpResults;
using Microsoft.EntityFrameworkCore;
using Procul.Api.Attachments;
using Procul.Api.Attachments.V1;
using Procul.Api.Chat.Models;
using Procul.Api.Infrastructure;

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
        return group;
    }

    private static async Task<Ok<GetConversationsResponseV1>> GetConversationsAsync(
        ProculDbContext db,
        CancellationToken ct
    )
    {
        var conversations = await db.Conversations
            .OrderByDescending(c => c.UpdatedAt)
            .ThenByDescending(c => c.Id)
            .Select(c => new ConversationV1(c.Id, c.Title, c.CreatedAt, c.UpdatedAt, c.Model))
            .ToListAsync(ct);

        return TypedResults.Ok(new GetConversationsResponseV1(conversations));
    }

    private static async Task<Results<ServerSentEventsResult<ChatStreamEventV1>, ProblemHttpResult>> CreateConversationAsync(
        ProculDbContext db,
        ChatStreamServiceV1 chat,
        ChatModelRegistry registry,
        ModelCatalogService catalog,
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

        var slug = model.Length > 0 ? model : null;
        var gate = await AttachmentGate.ResolveAsync(db, registry, catalog, body.AttachmentIds, slug, ct);
        if (!gate.IsValid)
        {
            return TypedResults.Problem(statusCode: StatusCodes.Status400BadRequest, detail: gate.Error);
        }

        var capabilities = catalog.GetCapabilities(registry.ResolveOrDefault(slug)).Input;

        var conversation = new Conversation
        {
            Title = ChatStreamServiceV1.FallbackTitle(body.InitialMessage),
            Model = slug,
        };
        db.Conversations.Add(conversation);
        await db.SaveChangesAsync(ct);

        return TypedResults.ServerSentEvents(
            chat.StreamNewConversationAsync(conversation, body.InitialMessage, gate.Attachments, capabilities, ct)
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
            .Select(c => new ConversationV1(c.Id, c.Title, c.CreatedAt, c.UpdatedAt, c.Model))
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

        conversation.Title = title;
        await db.SaveChangesAsync(ct);

        return TypedResults.Ok(new GetConversationResponseV1(
            new ConversationV1(conversation.Id, conversation.Title, conversation.CreatedAt, conversation.UpdatedAt, conversation.Model)
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

        conversation.Model = model;
        await db.SaveChangesAsync(ct);

        return TypedResults.Ok(new GetConversationResponseV1(
            new ConversationV1(conversation.Id, conversation.Title, conversation.CreatedAt, conversation.UpdatedAt, conversation.Model)
        ));
    }

    private static async Task<Results<NoContent, NotFound>> DeleteConversationAsync(
        Guid conversationId,
        ProculDbContext db,
        CancellationToken ct
    )
    {
        var conversation = await db.Conversations.FirstOrDefaultAsync(c => c.Id == conversationId, ct);
        if (conversation is null)
        {
            return TypedResults.NotFound();
        }

        // Messages are removed by the cascade configured on the foreign key.
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

        var messages = await query
            .OrderByDescending(m => m.CreatedAt)
            .ThenByDescending(m => m.Id)
            .Take(limit)
            .Select(m => new ConversationMessageV1(
                Id: m.Id,
                ConversationId: conversationId,
                Text: m.Text,
                MessageRole: m.MessageRole,
                CreatedAt: m.CreatedAt,
                Attachments: m.Attachments
                    .Select(a => new AttachmentV1(a.Id, a.FileName, a.ContentType, a.SizeBytes, a.CreatedAt))
                    .ToList()))
            .ToListAsync(ct);

        return TypedResults.Ok(new GetConversationMessagesResponseV1(messages));
    }

    private static async Task<Results<ServerSentEventsResult<ChatStreamEventV1>, NotFound, ProblemHttpResult>> SendMessageAsync(
        ProculDbContext db,
        ChatStreamServiceV1 chat,
        ChatModelRegistry registry,
        ModelCatalogService catalog,
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

        var gate = await AttachmentGate.ResolveAsync(db, registry, catalog, body.AttachmentIds, conversation.Model, ct);
        if (!gate.IsValid)
        {
            return TypedResults.Problem(statusCode: StatusCodes.Status400BadRequest, detail: gate.Error);
        }

        var capabilities = catalog.GetCapabilities(registry.ResolveOrDefault(conversation.Model)).Input;

        return TypedResults.ServerSentEvents(
            chat.StreamAssistantReplyAsync(conversationId, body.Text, gate.Attachments, capabilities, ct)
        );
    }
}
