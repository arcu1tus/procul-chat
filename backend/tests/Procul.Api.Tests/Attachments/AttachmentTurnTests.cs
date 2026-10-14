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
        bool resendHistory = false,
        ChatModelRegistry? registry = null) =>
        new(
            db,
            registry ?? ChatModelTestHelpers.Registry((ChatModelTestHelpers.Definition(capabilities: Caps), client)),
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
    public async Task Unsupported_history_is_not_opened_even_when_resending_is_enabled()
    {
        await using var db = NewDb();
        var conversation = new Conversation();
        var old = new ConversationMessage { ConversationId = conversation.Id, MessageRole = MessageRole.User, Text = "photo" };
        old.Attachments.Add(new Attachment { ConversationId = conversation.Id, MessageId = old.Id, FileName = "old.png", ContentType = "image/png", SizeBytes = 100, StorageKey = "never-open" });
        db.Conversations.Add(conversation);
        db.ConversationMessages.Add(old);
        await db.SaveChangesAsync();
        var captured = new List<ChatMessage>();
        async IAsyncEnumerable<ChatResponseUpdate> Capture()
        {
            // The fake below fills captured synchronously at invocation.
            yield return new(ChatRole.Assistant, "ok");
            await Task.CompletedTask;
        }
        var client = new FakeChatClient((_, _, _) => throw new NotSupportedException(), (messages, _, _) => { captured.AddRange(messages); return Capture(); });
        var store = new FakeAttachmentStore();
        var service = NewService(db, client, store, resendHistory: true);
        var textOnly = new HashSet<ModelInputModality> { ModelInputModality.Text };
        await foreach (var e in service.StreamAssistantReplyAsync(conversation.Id, "continue", [], textOnly, CancellationToken.None)) { }
        Assert.Equal(0, store.ReadCount);
        Assert.Empty(captured.SelectMany(m => m.Contents).OfType<DataContent>());
        Assert.Contains(old.Attachments[0].Id.ToString(), string.Join(" ", captured.Select(m => m.Text)));
    }

    [Fact]
    public async Task An_accepted_model_definition_survives_a_later_conversation_model_change()
    {
        await using var db = NewDb();
        var definition = ChatModelTestHelpers.Definition();
        var conversation = new Conversation { Model = "changed-later" };
        db.Conversations.Add(conversation);
        await db.SaveChangesAsync();
        var acceptedCalls = 0;
        var laterCalls = 0;
        var client = new FakeChatClient((_, _, _) => throw new NotSupportedException(), (_, _, _) => { acceptedCalls++; return Activity(); });
        var laterClient = new FakeChatClient((_, _, _) => throw new NotSupportedException(), (_, _, _) => { laterCalls++; return Activity(); });
        var registry = ChatModelTestHelpers.Registry((definition, client),
            (ChatModelTestHelpers.Definition("changed-later", isDefault: false), laterClient));
        var service = NewService(db, client, new FakeAttachmentStore(), registry: registry);
        await foreach (var e in service.StreamAssistantReplyAsync(conversation.Id, "test", [], Caps, CancellationToken.None, definition)) { }
        var saved = await db.ConversationMessages.SingleAsync(m => m.MessageRole == MessageRole.Assistant);
        Assert.Equal(1, acceptedCalls);
        Assert.Equal(0, laterCalls);
        Assert.Equal(definition.Slug, saved.Model);
    }

    [Fact]
    public async Task Disposing_a_turn_preserves_interrupted_tool_activity()
    {
        await using var db = NewDb();
        var conversation = new Conversation();
        db.Conversations.Add(conversation);
        await db.SaveChangesAsync();
        var client = new FakeChatClient((_, _, _) => throw new NotSupportedException(), (_, _, _) => Activity());
        var service = NewService(db, client, new FakeAttachmentStore());
        var turn = service.StreamAssistantReplyAsync(conversation.Id, "test", [], Caps, CancellationToken.None).GetAsyncEnumerator();
        Assert.True(await turn.MoveNextAsync()); // processing
        Assert.IsType<ChatStreamEventV1.Processing>(turn.Current);
        Assert.True(await turn.MoveNextAsync()); // reasoning
        Assert.IsType<ChatStreamEventV1.Reasoning>(turn.Current);
        Assert.True(await turn.MoveNextAsync()); // tool call
        Assert.IsType<ChatStreamEventV1.ToolCall>(turn.Current);
        await turn.DisposeAsync();
        var saved = await db.ConversationMessages.Include(m => m.ToolCalls).SingleAsync(m => m.MessageRole == MessageRole.Assistant);
        Assert.Equal("interrupted", saved.CompletionStatus);
        Assert.Equal("interrupted", Assert.Single(saved.ToolCalls).Status);
        Assert.Equal("visible thinking", saved.Reasoning);
    }

    [Fact]
    public async Task A_failed_turn_preserves_reasoning_and_marks_unfinished_tools_failed()
    {
        await using var db = NewDb();
        var conversation = new Conversation();
        db.Conversations.Add(conversation);
        await db.SaveChangesAsync();
        var client = new FakeChatClient((_, _, _) => throw new NotSupportedException(), (_, _, _) => Fails());
        var service = NewService(db, client, new FakeAttachmentStore());
        await foreach (var e in service.StreamAssistantReplyAsync(conversation.Id, "test", [], Caps, CancellationToken.None)) { }
        var saved = await db.ConversationMessages.Include(m => m.ToolCalls).SingleAsync(m => m.MessageRole == MessageRole.Assistant);
        Assert.Equal("failed", saved.CompletionStatus);
        Assert.Equal("failed", saved.ToolCalls.Single().Status);
        Assert.Equal("thinking", saved.Reasoning);
    }
    private static async IAsyncEnumerable<ChatResponseUpdate> Fails()
    {
        yield return new(ChatRole.Assistant, [new TextReasoningContent("thinking"), new FunctionCallContent("pending", "tool")]);
        await Task.Yield();
        throw new InvalidOperationException("provider failed");
    }

    [Fact]
    public async Task Reasoning_and_null_result_tool_calls_are_saved_and_do_not_enter_answer_text()
    {
        await using var db = NewDb();
        var conversation = new Conversation();
        db.Conversations.Add(conversation);
        await db.SaveChangesAsync();
        var client = new FakeChatClient((_, _, _) => throw new NotSupportedException(), (_, _, _) => Activity());
        var service = NewService(db, client, new FakeAttachmentStore());
        var events = new List<ChatStreamEventV1>();
        await foreach (var e in service.StreamAssistantReplyAsync(conversation.Id, "test", [], Caps, CancellationToken.None)) events.Add(e);
        Assert.Single(events.OfType<ChatStreamEventV1.Reasoning>());
        var saved = await db.ConversationMessages.Include(m => m.ToolCalls).SingleAsync(m => m.MessageRole == MessageRole.Assistant);
        Assert.Equal("answer", saved.Text);
        Assert.Equal("visible thinking", saved.Reasoning);
        Assert.Equal("completed", Assert.Single(saved.ToolCalls).Status);
    }

    private static async IAsyncEnumerable<ChatResponseUpdate> Activity()
    {
        yield return new(ChatRole.Assistant, [new TextReasoningContent("visible thinking") { ProtectedData = "never display" }]);
        yield return new(ChatRole.Assistant, [new FunctionCallContent("c", "tool")]);
        yield return new(ChatRole.Tool, [new FunctionResultContent("c", null)]);
        yield return new(ChatRole.Assistant, "answer");
        await Task.CompletedTask;
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
