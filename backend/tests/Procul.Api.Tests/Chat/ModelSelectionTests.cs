using System.Runtime.CompilerServices;
using Microsoft.EntityFrameworkCore;
using Microsoft.Extensions.AI;
using Microsoft.Extensions.Logging.Abstractions;
using Procul.Api.Chat;
using Procul.Api.Chat.Models;
using Procul.Api.Chat.V1;
using Procul.Api.Configuration;
using Procul.Api.Infrastructure;
using Procul.Api.Tests.Support;

namespace Procul.Api.Tests.Chat;

/// <summary>
/// Verifies the turn routes to the conversation's selected model, falls back to the default for a
/// stale slug, and stamps the model slug on the usage row. Uses an in-memory context and fake
/// clients — no network, no Postgres.
/// </summary>
public class ModelSelectionTests
{
    private static ProculDbContext NewDb()
    {
        var options = new DbContextOptionsBuilder<ProculDbContext>()
            .UseInMemoryDatabase($"selection-{Guid.NewGuid():N}")
            .Options;
        return new ProculDbContext(options);
    }

    private static FakeChatClient Streaming(string reply) => new(
        (_, _, _) => Task.FromResult(new ChatResponse(new ChatMessage(ChatRole.Assistant, reply))),
        (_, _, _) => Updates(reply));

    private static async IAsyncEnumerable<ChatResponseUpdate> Updates(
        string reply,
        [EnumeratorCancellation] CancellationToken ct = default)
    {
        yield return new ChatResponseUpdate(ChatRole.Assistant, reply);
        yield return new ChatResponseUpdate(ChatRole.Assistant, new List<AIContent>
        {
            new UsageContent(new UsageDetails { InputTokenCount = 1, OutputTokenCount = 1 }),
        });
        await Task.CompletedTask;
    }

    private static ChatStreamServiceV1 NewService(ProculDbContext db, ChatModelRegistry registry) =>
        new(db, registry, new ModelUsageTracker(), new ProculConfig(),
            McpTestHelpers.DisabledManager(), new FakeAttachmentStore(), TestAttachmentOptions.Create(),
            Procul.Api.Chat.Tools.TurnToolFactory.CreateForTests(),
            NullLogger<ChatStreamServiceV1>.Instance);

    private static async Task<string> RunTurnAsync(ChatStreamServiceV1 service, Guid conversationId)
    {
        var reply = string.Empty;
        await foreach (var evt in service.StreamAssistantReplyAsync(
            conversationId,
            "hi",
            [],
            new HashSet<ModelInputModality> { ModelInputModality.Text },
            CancellationToken.None))
        {
            if (evt is ChatStreamEventV1.Token token)
            {
                reply += token.Value.Content;
            }
        }

        return reply;
    }

    [Fact]
    public async Task A_conversation_model_is_persisted()
    {
        await using var db = NewDb();
        var conversation = new Conversation { Title = "t", Model = "b" };
        db.Conversations.Add(conversation);
        await db.SaveChangesAsync();

        var reloaded = await db.Conversations.SingleAsync(c => c.Id == conversation.Id);
        Assert.Equal("b", reloaded.Model);
    }

    [Fact]
    public async Task A_turn_uses_the_conversations_model()
    {
        await using var db = NewDb();
        var conversation = new Conversation { Title = "t", Model = "b" };
        db.Conversations.Add(conversation);
        await db.SaveChangesAsync();

        var registry = ChatModelTestHelpers.Registry(
            (ChatModelTestHelpers.Definition("a"), Streaming("from-a")),
            (ChatModelTestHelpers.Definition("b", isDefault: false), Streaming("from-b")));

        var reply = await RunTurnAsync(NewService(db, registry), conversation.Id);

        Assert.Equal("from-b", reply);
        Assert.Equal("b", (await db.TurnUsages.SingleAsync()).Model);
    }

    [Fact]
    public async Task A_stale_slug_falls_back_to_the_default()
    {
        await using var db = NewDb();
        var conversation = new Conversation { Title = "t", Model = "ghost" };
        db.Conversations.Add(conversation);
        await db.SaveChangesAsync();

        var registry = ChatModelTestHelpers.Registry(
            (ChatModelTestHelpers.Definition("a"), Streaming("from-a")),
            (ChatModelTestHelpers.Definition("b", isDefault: false), Streaming("from-b")));

        var reply = await RunTurnAsync(NewService(db, registry), conversation.Id);

        Assert.Equal("from-a", reply);
        Assert.Equal("a", (await db.TurnUsages.SingleAsync()).Model);
    }

    [Fact]
    public async Task The_reply_usage_row_points_at_the_assistant_message_and_bumps_the_revision()
    {
        await using var db = NewDb();
        var conversation = new Conversation { Title = "t" };
        db.Conversations.Add(conversation);
        await db.SaveChangesAsync();

        var registry = ChatModelTestHelpers.Registry((ChatModelTestHelpers.Definition("a"), Streaming("hi")));
        await RunTurnAsync(NewService(db, registry), conversation.Id);

        var assistant = await db.ConversationMessages.SingleAsync(m => m.MessageRole == MessageRole.Assistant);
        var usage = await db.TurnUsages.SingleAsync();

        Assert.Equal(assistant.Id, usage.MessageId);
        Assert.Equal(1, (await db.Conversations.SingleAsync()).Revision);
    }
}
