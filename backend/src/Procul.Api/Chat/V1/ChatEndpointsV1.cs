using System.Net.ServerSentEvents;
using System.Runtime.CompilerServices;
using Microsoft.AspNetCore.Http.HttpResults;
using Microsoft.EntityFrameworkCore;
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
            .Select(c => new ConversationV1(c.Id, c.Title, c.CreatedAt, c.UpdatedAt))
            .ToListAsync(ct);

        return TypedResults.Ok(new GetConversationsResponseV1(conversations));
    }

    private static async Task<ServerSentEventsResult<ChatStreamEventV1>> CreateConversationAsync(
        ProculDbContext db,
        ChatStreamServiceV1 chat,
        CreateConversationRequestV1 body,
        CancellationToken ct
    )
    {
        var conversation = new Conversation { Title = ChatStreamServiceV1.FallbackTitle(body.InitialMessage) };
        db.Conversations.Add(conversation);
        await db.SaveChangesAsync(ct);

        return TypedResults.ServerSentEvents(StreamAsync(conversation, body.InitialMessage, db, chat, ct));

        static async IAsyncEnumerable<SseItem<ChatStreamEventV1>> StreamAsync(
            Conversation conversation,
            string initialMessage,
            ProculDbContext db,
            ChatStreamServiceV1 chat,
            [EnumeratorCancellation] CancellationToken ct
        )
        {
            yield return new SseItem<ChatStreamEventV1>(
                new ChatStreamEventV1.Created(
                    new ChatStreamCreatedV1(
                        new ConversationV1(conversation.Id, conversation.Title, conversation.CreatedAt, conversation.UpdatedAt)
                    )
                )
            );

            // Start the title model call now so it runs concurrently with the reply. It only
            // produces a string; the DB write happens below, after the stream, so a single
            // DbContext is never used from two places at once.
            var titleTask = chat.GenerateTitleAsync(initialMessage, ct);

            await foreach (var streamEvent in chat.StreamAssistantReplyAsync(conversation.Id, initialMessage, ct))
            {
                yield return new SseItem<ChatStreamEventV1>(streamEvent);
            }

            var title = await titleTask ?? ChatStreamServiceV1.FallbackTitle(initialMessage);
            conversation.Title = title;
            await db.SaveChangesAsync(ct);

            yield return new SseItem<ChatStreamEventV1>(
                new ChatStreamEventV1.Title(new ChatStreamTitleV1(conversation.Id, title))
            );
        }
    }

    private static async Task<Results<Ok<GetConversationResponseV1>, NotFound>> GetConversationAsync(
        Guid conversationId,
        ProculDbContext db,
        CancellationToken ct
    )
    {
        var conversation = await db.Conversations
            .Where(c => c.Id == conversationId)
            .Select(c => new ConversationV1(c.Id, c.Title, c.CreatedAt, c.UpdatedAt))
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
            new ConversationV1(conversation.Id, conversation.Title, conversation.CreatedAt, conversation.UpdatedAt)
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

    private static async Task<Results<Ok<GetConversationMessagesResponsev1>, ProblemHttpResult>> GetConversationMessagesAsync(
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
            .Select(m => new ConversationMessageV1(Id: m.Id, ConversationId: conversationId, Text: m.Text, MessageRole: m.MessageRole, CreatedAt: m.CreatedAt))
            .ToListAsync(ct);

        return TypedResults.Ok(new GetConversationMessagesResponsev1(messages));
    }

    private static async Task<Results<ServerSentEventsResult<ChatStreamEventV1>, NotFound>> SendMessageAsync(
        ProculDbContext db,
        ChatStreamServiceV1 chat,
        Guid conversationId,
        SendMessageRequestV1 body,
        CancellationToken ct
    )
    {
        var conversationExists = await db.Conversations.AnyAsync(c => c.Id == conversationId, ct);
        if (!conversationExists)
        {
            return TypedResults.NotFound();
        }

        return TypedResults.ServerSentEvents(
            chat.StreamAssistantReplyAsync(conversationId, body.Text, ct)
        );
    }
}
