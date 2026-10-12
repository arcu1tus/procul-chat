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

namespace Procul.Api.Tests.Attachments;

/// <summary>
/// Drives a whole turn through <see cref="ChatStreamServiceV1"/> with a capturing client, so the
/// content parts the model actually receives are asserted: the user text first, then the
/// attachment parts (or a placeholder), plus the history-note behavior.
/// </summary>
public class AttachmentTurnTests
{
    private static ProculDbContext NewDb() =>
        new(new DbContextOptionsBuilder<ProculDbContext>()
            .UseInMemoryDatabase($"turn-{Guid.NewGuid():N}")
            .Options);

    private static readonly HashSet<ModelInputModality> Caps =
        [ModelInputModality.Text, ModelInputModality.Image, ModelInputModality.Pdf, ModelInputModality.Audio];

    private static ChatStreamServiceV1 NewService(
        ProculDbContext db,
        IChatClient client,
        FakeAttachmentStore store,
        bool resendHistory = false) =>
        new(
            db,
            ChatModelTestHelpers.Registry((ChatModelTestHelpers.Definition(capabilities: Caps), client)),
            new ModelUsageTracker(),
            new ProculConfig(),
            McpTestHelpers.DisabledManager(),
            store,
            TestAttachmentOptions.Create(resendHistory: resendHistory),
            Procul.Api.Chat.Tools.TurnToolFactory.CreateForTests(),
            NullLogger<ChatStreamServiceV1>.Instance);

    private static FakeChatClient Capturing(List<ChatMessage> captured) => new(
        (_, _, _) => Task.FromResult(new ChatResponse(new ChatMessage(ChatRole.Assistant, "ok"))),
        (messages, _, ct) => Reply(messages, captured, ct));

    private static async IAsyncEnumerable<ChatResponseUpdate> Reply(
        IEnumerable<ChatMessage> messages,
        List<ChatMessage> captured,
        [EnumeratorCancellation] CancellationToken ct = default)
    {
        captured.AddRange(messages);
        yield return new ChatResponseUpdate(ChatRole.Assistant, "ok");
        await Task.CompletedTask;
    }

    private static async Task<Attachment> SeedAsync(
        ProculDbContext db,
        FakeAttachmentStore store,
        Guid conversationId,
        string fileName,
        string contentType)
    {
        var attachment = new Attachment
        {
            FileName = fileName,
            ContentType = contentType,
            SizeBytes = 3,
            Sha256 = "x",
        };
        db.Attachments.Add(attachment);
        await db.SaveChangesAsync();

        attachment.StorageKey = await store.PutAsync(
            attachment, new MemoryStream(new byte[] { 1, 2, 3 }), CancellationToken.None);
        await db.SaveChangesAsync();
        return attachment;
    }

    private static async Task<List<ChatMessage>> RunTurnAsync(
        ChatStreamServiceV1 service,
        List<ChatMessage> captured,
        Guid conversationId,
        string text,
        IReadOnlyList<Attachment> attachments,
        IReadOnlySet<ModelInputModality>? capabilities = null)
    {
        captured.Clear();
        await foreach (var _ in service.StreamAssistantReplyAsync(
            conversationId, text, attachments, capabilities ?? Caps, CancellationToken.None))
        {
        }

        return captured;
    }

    [Fact]
    public async Task The_current_turns_attachments_are_sent_as_content_parts()
    {
        await using var db = NewDb();
        var conversation = new Conversation { Title = "t" };
        db.Conversations.Add(conversation);
        await db.SaveChangesAsync();

        var store = new FakeAttachmentStore();
        var attachment = await SeedAsync(db, store, conversation.Id, "cat.png", "image/png");

        var captured = new List<ChatMessage>();
        var service = NewService(db, Capturing(captured), store);

        await RunTurnAsync(service, captured, conversation.Id, "look", [attachment]);

        var user = captured.Last();
        Assert.Equal(ChatRole.User, user.Role);
        Assert.Equal("look", user.Contents.OfType<TextContent>().First().Text);
        var image = Assert.IsType<DataContent>(user.Contents.OfType<DataContent>().Single());
        Assert.Equal("image/png", image.MediaType);
    }

    [Fact]
    public async Task The_attachment_is_persisted_against_the_user_message()
    {
        await using var db = NewDb();
        var conversation = new Conversation { Title = "t" };
        db.Conversations.Add(conversation);
        await db.SaveChangesAsync();

        var store = new FakeAttachmentStore();
        var attachment = await SeedAsync(db, store, conversation.Id, "report.pdf", "application/pdf");

        var captured = new List<ChatMessage>();
        var service = NewService(db, Capturing(captured), store);

        await RunTurnAsync(service, captured, conversation.Id, "here", [attachment]);

        var persisted = await db.Attachments.SingleAsync();
        Assert.NotNull(persisted.MessageId);
        Assert.Equal(conversation.Id, persisted.ConversationId);
    }

    [Fact]
    public async Task History_without_resend_contributes_a_note_not_the_bytes()
    {
        await using var db = NewDb();
        var conversation = new Conversation { Title = "t" };
        db.Conversations.Add(conversation);
        await db.SaveChangesAsync();

        var store = new FakeAttachmentStore();
        var attachment = await SeedAsync(db, store, conversation.Id, "cat.png", "image/png");

        var captured = new List<ChatMessage>();
        var service = NewService(db, Capturing(captured), store);

        // First turn carries the bytes.
        await RunTurnAsync(service, captured, conversation.Id, "first", [attachment]);
        Assert.Contains(captured.Last().Contents, content => content is DataContent);

        // Second turn: the earlier user turn's attachment is now a note, not the bytes.
        await RunTurnAsync(service, captured, conversation.Id, "second", []);
        var historyUser = captured[1]; // [system, firstUser, firstAssistant, secondUser]
        Assert.Equal(ChatRole.User, historyUser.Role);
        Assert.DoesNotContain(historyUser.Contents, content => content is DataContent);
        Assert.Contains(
            historyUser.Contents.OfType<TextContent>(),
            text => text.Text.Contains("cat.png") && !text.Text.Contains("not sent"));
    }

    [Fact]
    public async Task History_with_resend_carries_the_bytes_again()
    {
        await using var db = NewDb();
        var conversation = new Conversation { Title = "t" };
        db.Conversations.Add(conversation);
        await db.SaveChangesAsync();

        var store = new FakeAttachmentStore();
        var attachment = await SeedAsync(db, store, conversation.Id, "cat.png", "image/png");

        var captured = new List<ChatMessage>();
        var service = NewService(db, Capturing(captured), store, resendHistory: true);

        await RunTurnAsync(service, captured, conversation.Id, "first", [attachment]);
        await RunTurnAsync(service, captured, conversation.Id, "second", []);

        var historyUser = captured[1];
        Assert.Contains(historyUser.Contents, content => content is DataContent);
    }

    [Fact]
    public async Task An_unsupported_attachment_is_replaced_with_a_placeholder()
    {
        await using var db = NewDb();
        var conversation = new Conversation { Title = "t" };
        db.Conversations.Add(conversation);
        await db.SaveChangesAsync();

        var store = new FakeAttachmentStore();
        var attachment = await SeedAsync(db, store, conversation.Id, "movie.mp4", "video/mp4");

        var captured = new List<ChatMessage>();
        var service = NewService(db, Capturing(captured), store);

        await RunTurnAsync(service, captured, conversation.Id, "watch", [attachment]);

        var user = captured.Last();
        Assert.DoesNotContain(user.Contents, content => content is DataContent);
        Assert.Contains(
            user.Contents.OfType<TextContent>(),
            text => text.Text.Contains("movie.mp4") && text.Text.Contains("not sent"));
    }

    [Fact]
    public async Task A_later_turn_on_an_incapable_model_receives_a_note_not_the_bytes()
    {
        await using var db = NewDb();
        var conversation = new Conversation { Title = "t" };
        db.Conversations.Add(conversation);
        await db.SaveChangesAsync();

        var store = new FakeAttachmentStore();
        var attachment = await SeedAsync(db, store, conversation.Id, "cat.png", "image/png");

        var captured = new List<ChatMessage>();
        var service = NewService(db, Capturing(captured), store, resendHistory: true);

        // First turn on a capable model: the bytes are sent.
        await RunTurnAsync(service, captured, conversation.Id, "first", [attachment]);
        Assert.Contains(captured.Last().Contents, content => content is DataContent);

        // A later turn on a text-only model: only a note, no bytes.
        var textOnly = new HashSet<ModelInputModality> { ModelInputModality.Text };
        await RunTurnAsync(service, captured, conversation.Id, "second", [], textOnly);

        var historyUser = captured[1];
        Assert.DoesNotContain(historyUser.Contents, content => content is DataContent);
        Assert.Contains(
            historyUser.Contents.OfType<TextContent>(),
            text => text.Text.Contains("cat.png") && text.Text.Contains("not sent"));
    }
}
