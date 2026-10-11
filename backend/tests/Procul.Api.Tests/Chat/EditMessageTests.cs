using System.Runtime.CompilerServices;
using Microsoft.EntityFrameworkCore;
using Microsoft.Extensions.AI;
using Microsoft.Extensions.Logging.Abstractions;
using Procul.Api.Attachments;
using Procul.Api.Chat;
using Procul.Api.Chat.Models;
using Procul.Api.Chat.V1;
using Procul.Api.Configuration;
using Procul.Api.Infrastructure;
using Procul.Api.Tests.Support;

namespace Procul.Api.Tests.Chat;

/// <summary>
/// Drives the destructive edit path through <see cref="ChatStreamServiceV1.EditMessageAsync"/> with
/// the in-memory provider and a fake client: the tail is truncated, usage rows for the discarded
/// turns are dropped, the edited text replaces the original, attachments are reconciled, and a fresh
/// assistant reply is persisted.
/// </summary>
public class EditMessageTests
{
    private static ProculDbContext NewDb() =>
        new(new DbContextOptionsBuilder<ProculDbContext>()
            .UseInMemoryDatabase($"edit-{Guid.NewGuid():N}")
            .Options);

    private static readonly HashSet<ModelInputModality> Caps =
        [ModelInputModality.Text, ModelInputModality.Image, ModelInputModality.Pdf, ModelInputModality.Audio];

    private static ChatStreamServiceV1 NewService(
        ProculDbContext db,
        IChatClient client,
        FakeAttachmentStore store) =>
        new(
            db,
            ChatModelTestHelpers.Registry((ChatModelTestHelpers.Definition(capabilities: Caps), client)),
            new ModelUsageTracker(),
            new ProculConfig(),
            McpTestHelpers.DisabledManager(),
            store,
            TestAttachmentOptions.Create(resendHistory: true),
            NullLogger<ChatStreamServiceV1>.Instance);

    /// <summary>A client that streams <paramref name="reply"/> plus a usage payload, so a reply's
    /// usage row is exercised.</summary>
    private static FakeChatClient Replying(string reply = "ok") => new(
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

    private static async Task<Conversation> SeedConversationAsync(ProculDbContext db)
    {
        var conversation = new Conversation { Title = "t" };
        db.Conversations.Add(conversation);
        await db.SaveChangesAsync();
        return conversation;
    }

    private static async Task<ConversationMessage> AddMessageAsync(
        ProculDbContext db,
        Guid conversationId,
        MessageRole role,
        string text,
        DateTimeOffset createdAt)
    {
        var message = new ConversationMessage
        {
            ConversationId = conversationId,
            Text = text,
            MessageRole = role,
            CreatedAt = createdAt,
        };
        db.ConversationMessages.Add(message);
        await db.SaveChangesAsync();
        return message;
    }

    /// <summary>Stores the bytes for <paramref name="attachment"/> and (when attached) persists it.</summary>
    private static async Task<Attachment> StoreAsync(
        ProculDbContext db,
        FakeAttachmentStore store,
        Guid? conversationId,
        Guid? messageId,
        string fileName,
        string contentType)
    {
        var attachment = new Attachment
        {
            FileName = fileName,
            ContentType = contentType,
            SizeBytes = 3,
            Sha256 = "x",
            ConversationId = conversationId,
            MessageId = messageId,
        };
        attachment.StorageKey = await store.PutAsync(
            attachment, new MemoryStream(new byte[] { 1, 2, 3 }), CancellationToken.None);
        db.Attachments.Add(attachment);
        await db.SaveChangesAsync();
        return attachment;
    }

    private static async Task<List<ChatStreamEventV1>> RunEditAsync(
        ChatStreamServiceV1 service,
        Guid conversationId,
        Guid messageId,
        string newText,
        IReadOnlyList<Attachment>? replacement = null)
    {
        var events = new List<ChatStreamEventV1>();
        await foreach (var streamEvent in service.EditMessageAsync(
            conversationId, messageId, newText, replacement, Caps, CancellationToken.None))
        {
            events.Add(streamEvent);
        }

        return events;
    }

    private static Task<List<ConversationMessage>> MessagesAsync(ProculDbContext db, Guid conversationId) =>
        db.ConversationMessages
            .Where(m => m.ConversationId == conversationId)
            .OrderBy(m => m.CreatedAt)
            .ThenBy(m => m.Id)
            .ToListAsync();

    [Fact]
    public async Task Editing_a_middle_message_truncates_the_tail_and_persists_one_reply()
    {
        await using var db = NewDb();
        var store = new FakeAttachmentStore();
        var conversation = await SeedConversationAsync(db);
        var t0 = DateTimeOffset.UtcNow.AddMinutes(-10);
        var m1 = await AddMessageAsync(db, conversation.Id, MessageRole.User, "first", t0);
        var m2 = await AddMessageAsync(db, conversation.Id, MessageRole.Assistant, "a1", t0.AddMinutes(1));
        var m3 = await AddMessageAsync(db, conversation.Id, MessageRole.User, "second", t0.AddMinutes(2));
        var m4 = await AddMessageAsync(db, conversation.Id, MessageRole.Assistant, "a2", t0.AddMinutes(3));

        var service = NewService(db, Replying("new reply"), store);
        var events = await RunEditAsync(service, conversation.Id, m1.Id, "first edited");

        var remaining = await MessagesAsync(db, conversation.Id);
        Assert.Equal(2, remaining.Count);
        Assert.Equal("first edited", remaining[0].Text);
        Assert.Equal(MessageRole.User, remaining[0].MessageRole);
        Assert.Equal("new reply", remaining[1].Text);
        Assert.Equal(MessageRole.Assistant, remaining[1].MessageRole);
        Assert.DoesNotContain(remaining, m => m.Id == m2.Id || m.Id == m3.Id || m.Id == m4.Id);

        Assert.IsType<ChatStreamEventV1.Done>(events.Last());
    }

    [Fact]
    public async Task Editing_leaves_earlier_messages_untouched()
    {
        await using var db = NewDb();
        var store = new FakeAttachmentStore();
        var conversation = await SeedConversationAsync(db);
        var t0 = DateTimeOffset.UtcNow.AddMinutes(-10);
        var m1 = await AddMessageAsync(db, conversation.Id, MessageRole.User, "first", t0);
        var m2 = await AddMessageAsync(db, conversation.Id, MessageRole.Assistant, "a1", t0.AddMinutes(1));
        var m3 = await AddMessageAsync(db, conversation.Id, MessageRole.User, "second", t0.AddMinutes(2));
        var m4 = await AddMessageAsync(db, conversation.Id, MessageRole.Assistant, "a2", t0.AddMinutes(3));

        var service = NewService(db, Replying("new reply"), store);
        await RunEditAsync(service, conversation.Id, m3.Id, "second edited");

        var remaining = await MessagesAsync(db, conversation.Id);
        // m1, m2, the edited m3, and the new reply — m4 is gone.
        Assert.Equal(4, remaining.Count);
        Assert.Equal("first", remaining[0].Text);
        Assert.Equal("a1", remaining[1].Text);
        Assert.Equal("second edited", remaining[2].Text);
        Assert.Equal("new reply", remaining[3].Text);
        Assert.DoesNotContain(remaining, m => m.Id == m4.Id);
    }

    [Fact]
    public async Task Attachments_on_discarded_messages_are_removed_from_store_and_db()
    {
        await using var db = NewDb();
        var store = new FakeAttachmentStore();
        var conversation = await SeedConversationAsync(db);
        var t0 = DateTimeOffset.UtcNow.AddMinutes(-10);
        var m1 = await AddMessageAsync(db, conversation.Id, MessageRole.User, "first", t0);
        var m2 = await AddMessageAsync(db, conversation.Id, MessageRole.User, "second", t0.AddMinutes(2));
        var a2 = await StoreAsync(db, store, conversation.Id, m2.Id, "gone.png", "image/png");
        Assert.NotNull(store.Get(a2.StorageKey));

        var service = NewService(db, Replying(), store);
        await RunEditAsync(service, conversation.Id, m1.Id, "first edited");

        Assert.Null(store.Get(a2.StorageKey));
        Assert.Null(await db.Attachments.FirstOrDefaultAsync(a => a.Id == a2.Id));
    }

    [Fact]
    public async Task A_null_replacement_keeps_the_messages_attachments()
    {
        await using var db = NewDb();
        var store = new FakeAttachmentStore();
        var conversation = await SeedConversationAsync(db);
        var t0 = DateTimeOffset.UtcNow.AddMinutes(-10);
        var m1 = await AddMessageAsync(db, conversation.Id, MessageRole.User, "first", t0);
        var a1 = await StoreAsync(db, store, conversation.Id, m1.Id, "keep.png", "image/png");

        var service = NewService(db, Replying(), store);
        await RunEditAsync(service, conversation.Id, m1.Id, "first edited", replacement: null);

        var kept = await db.Attachments.SingleAsync(a => a.Id == a1.Id);
        Assert.Equal(m1.Id, kept.MessageId);
        Assert.NotNull(store.Get(a1.StorageKey));
    }

    [Fact]
    public async Task An_empty_replacement_removes_all_attachments()
    {
        await using var db = NewDb();
        var store = new FakeAttachmentStore();
        var conversation = await SeedConversationAsync(db);
        var t0 = DateTimeOffset.UtcNow.AddMinutes(-10);
        var m1 = await AddMessageAsync(db, conversation.Id, MessageRole.User, "first", t0);
        var a1 = await StoreAsync(db, store, conversation.Id, m1.Id, "drop.png", "image/png");

        var service = NewService(db, Replying(), store);
        await RunEditAsync(service, conversation.Id, m1.Id, "first edited", replacement: []);

        Assert.Null(await db.Attachments.FirstOrDefaultAsync(a => a.Id == a1.Id));
        Assert.Null(store.Get(a1.StorageKey));
    }

    [Fact]
    public async Task A_replacement_set_swaps_the_attachments()
    {
        await using var db = NewDb();
        var store = new FakeAttachmentStore();
        var conversation = await SeedConversationAsync(db);
        var t0 = DateTimeOffset.UtcNow.AddMinutes(-10);
        var m1 = await AddMessageAsync(db, conversation.Id, MessageRole.User, "first", t0);
        var old = await StoreAsync(db, store, conversation.Id, m1.Id, "old.png", "image/png");
        var replacement = await StoreAsync(db, store, null, null, "new.png", "image/png");

        var service = NewService(db, Replying(), store);
        await RunEditAsync(service, conversation.Id, m1.Id, "first edited", replacement: [replacement]);

        Assert.Null(store.Get(old.StorageKey));
        Assert.Null(await db.Attachments.FirstOrDefaultAsync(a => a.Id == old.Id));

        var attached = await db.Attachments.SingleAsync(a => a.Id == replacement.Id);
        Assert.Equal(m1.Id, attached.MessageId);
        Assert.Equal(conversation.Id, attached.ConversationId);

        var reloaded = await db.ConversationMessages
            .Include(m => m.Attachments)
            .SingleAsync(m => m.Id == m1.Id);
        Assert.Equal(replacement.Id, reloaded.Attachments.Single().Id);
    }

    [Fact]
    public async Task Discarded_turns_usage_rows_are_deleted_and_the_reply_adds_one()
    {
        await using var db = NewDb();
        var store = new FakeAttachmentStore();
        var conversation = await SeedConversationAsync(db);
        var t0 = DateTimeOffset.UtcNow.AddMinutes(-10);
        var m1 = await AddMessageAsync(db, conversation.Id, MessageRole.User, "first", t0);
        await AddMessageAsync(db, conversation.Id, MessageRole.Assistant, "a1", t0.AddMinutes(1));

        // A usage row from the discarded reply (created after the edited message).
        db.TurnUsages.Add(new TurnUsage
        {
            ConversationId = conversation.Id,
            Model = "test/model",
            Kind = TurnKind.Chat,
            CreatedAt = t0.AddMinutes(1),
        });
        await db.SaveChangesAsync();

        var service = NewService(db, Replying(), store);
        await RunEditAsync(service, conversation.Id, m1.Id, "first edited");

        var usage = await db.TurnUsages.Where(u => u.ConversationId == conversation.Id).ToListAsync();
        Assert.Single(usage);
        Assert.Equal(TurnKind.Chat, usage[0].Kind);
        Assert.True(usage[0].CreatedAt > t0);
    }

    [Fact]
    public async Task Editing_bumps_the_conversations_updated_at()
    {
        await using var db = NewDb();
        var store = new FakeAttachmentStore();
        var conversation = await SeedConversationAsync(db);
        conversation.UpdatedAt = DateTimeOffset.UtcNow.AddHours(-1);
        await db.SaveChangesAsync();
        var previous = conversation.UpdatedAt;

        var t0 = DateTimeOffset.UtcNow.AddMinutes(-10);
        var m1 = await AddMessageAsync(db, conversation.Id, MessageRole.User, "first", t0);

        var service = NewService(db, Replying(), store);
        await RunEditAsync(service, conversation.Id, m1.Id, "first edited");

        var reloaded = await db.Conversations.SingleAsync(c => c.Id == conversation.Id);
        Assert.True(reloaded.UpdatedAt > previous);
    }
}
