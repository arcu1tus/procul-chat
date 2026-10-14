using System.ComponentModel;
using System.Runtime.CompilerServices;
using Microsoft.EntityFrameworkCore;
using Microsoft.Extensions.AI;
using Microsoft.Extensions.Logging.Abstractions;
using Procul.Api.Attachments;
using Procul.Api.Chat;
using Procul.Api.Chat.Models;
using Procul.Api.Chat.Tools;
using Procul.Api.Chat.V1;
using Procul.Api.Configuration;
using Procul.Api.Images;
using Procul.Api.Infrastructure;
using Procul.Api.Tests.Support;
using ImageGenerationOptions = Procul.Api.Configuration.ImageGenerationOptions;
using ImageGenerationRequest = Procul.Api.Images.ImageGenerationRequest;

namespace Procul.Api.Tests.Chat.Tools;

/// <summary>
/// Exercises the <c>generate_image</c> tool directly (the way <c>UseFunctionInvocation()</c> would)
/// and end-to-end through a turn driven by a client that invokes the tool, asserting the image is
/// stored, the <c>image</c> event is emitted, and the generated attachment is linked to the
/// assistant message.
/// </summary>
public class ImageGenerationToolTests
{
    private static ProculDbContext NewDb() =>
        new(new DbContextOptionsBuilder<ProculDbContext>()
            .UseInMemoryDatabase($"imagegen-{Guid.NewGuid():N}")
            .Options);

    private static ImageGenerationOptions EnabledOptions() =>
        ImageGenerationOptions.FromConfig(new ProculConfig
        {
            ImageGeneration = new ImageGenerationConfig
            {
                Enabled = true,
                Model = "google/gemini-2.5-flash-image",
                MaxReferenceImages = 2,
            },
        });

    private static TurnToolContext Context(ProculDbContext db, FakeAttachmentStore store, Guid conversationId) =>
        new(db, store, TestAttachmentOptions.Create(), conversationId, "test/model", new GeneratedMediaCollector());

    private static async Task<Attachment> SeedImageAsync(
        ProculDbContext db,
        FakeAttachmentStore store,
        Guid conversationId,
        string fileName = "ref.png",
        byte[]? bytes = null)
    {
        var attachment = new Attachment
        {
            FileName = fileName,
            ContentType = "image/png",
            SizeBytes = 8,
            Sha256 = "x",
            ConversationId = conversationId,
        };
        db.Attachments.Add(attachment);
        await db.SaveChangesAsync();

        attachment.StorageKey = await store.PutAsync(
            attachment,
            new MemoryStream(bytes ?? [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]),
            CancellationToken.None);
        await db.SaveChangesAsync();
        return attachment;
    }

    private static string AsText(object? result) => result switch
    {
        System.Text.Json.JsonElement { ValueKind: System.Text.Json.JsonValueKind.String } element =>
            element.GetString() ?? string.Empty,
        System.Text.Json.JsonElement element => element.GetRawText(),
        string text => text,
        null => string.Empty,
        _ => result.ToString() ?? string.Empty,
    };

    [Fact]
    public async Task Reference_selection_preserves_order_and_rejects_excess_or_expired_images()
    {
        await using var db = NewDb();
        var store = new FakeAttachmentStore();
        var conversationId = Guid.NewGuid();
        var first = await SeedImageAsync(db, store, conversationId, "first.png", [1]);
        var second = await SeedImageAsync(db, store, conversationId, "second.png", [2]);
        var third = await SeedImageAsync(db, store, conversationId, "third.png", [3]);
        var client = new FakeImageGenerationClient();
        var tool = new ImageGenerationTool(client, EnabledOptions(), Context(db, store, conversationId), NullLogger.Instance).Create();
        await tool.InvokeAsync(new AIFunctionArguments { ["prompt"] = "edit", ["referenceAttachmentIds"] = new[] { second.Id, first.Id, second.Id } });
        Assert.Equal(new byte[] { 2 }, client.LastRequest!.References[0].Bytes);
        Assert.Equal(new byte[] { 1 }, client.LastRequest.References[1].Bytes);
        var excess = await tool.InvokeAsync(new AIFunctionArguments { ["prompt"] = "edit", ["referenceAttachmentIds"] = new[] { first.Id, second.Id, third.Id } });
        Assert.Contains("at most 2", AsText(excess));
        Assert.Equal(1, client.CallCount);
        await store.DeleteAsync(first.StorageKey, CancellationToken.None);
        var expired = await tool.InvokeAsync(new AIFunctionArguments { ["prompt"] = "edit", ["referenceAttachmentIds"] = new[] { first.Id } });
        Assert.Contains("no longer stored", AsText(expired));
        Assert.Equal(1, client.CallCount);
    }

    [Fact]
    public async Task Stores_the_image_and_enqueues_an_image_event()
    {
        await using var db = NewDb();
        var store = new FakeAttachmentStore();
        var client = new FakeImageGenerationClient();
        var context = Context(db, store, Guid.NewGuid());

        var tool = new ImageGenerationTool(client, EnabledOptions(), context, NullLogger.Instance).Create();
        var result = await tool.InvokeAsync(new AIFunctionArguments { ["prompt"] = "a cat" });

        Assert.Contains("Generated an image", AsText(result));

        var stored = await db.Attachments.SingleAsync();
        Assert.Equal(Attachment.SourceGenerated, stored.Source);
        Assert.StartsWith("generated-", stored.FileName);
        Assert.Null(stored.MessageId);
        Assert.NotNull(store.Get(stored.StorageKey));

        Assert.True(context.Media.TryDequeueEvent(out var imageEvent));
        var image = Assert.IsType<ChatStreamEventV1.Image>(imageEvent);
        Assert.Equal(stored.Id, image.Value.AttachmentId);
        Assert.Null(stored.MessageId);
    }

    [Fact]
    public async Task Reference_images_are_passed_to_the_client()
    {
        await using var db = NewDb();
        var store = new FakeAttachmentStore();
        var conversationId = Guid.NewGuid();
        var reference = await SeedImageAsync(db, store, conversationId);
        var client = new FakeImageGenerationClient();

        var context = Context(db, store, conversationId);
        var tool = new ImageGenerationTool(client, EnabledOptions(), context, NullLogger.Instance).Create();
        await tool.InvokeAsync(new AIFunctionArguments
        {
            ["prompt"] = "a cat in a hat",
            ["referenceAttachmentIds"] = new[] { reference.Id },
        });

        var request = Assert.IsType<ImageGenerationRequest>(client.LastRequest);
        var sent = Assert.Single(request.References);
        Assert.Equal("image/png", sent.ContentType);
        Assert.Equal(8, sent.Bytes.Length);
    }

    [Fact]
    public async Task A_reference_from_another_conversation_is_rejected()
    {
        await using var db = NewDb();
        var store = new FakeAttachmentStore();
        // The image belongs to a different conversation than the turn's context.
        var reference = await SeedImageAsync(db, store, Guid.NewGuid());
        var client = new FakeImageGenerationClient();

        var context = Context(db, store, Guid.NewGuid());
        var tool = new ImageGenerationTool(client, EnabledOptions(), context, NullLogger.Instance).Create();
        var result = await tool.InvokeAsync(new AIFunctionArguments
        {
            ["prompt"] = "a cat",
            ["referenceAttachmentIds"] = new[] { reference.Id },
        });

        Assert.Contains("Unknown reference attachment id", AsText(result));
        Assert.Equal(0, client.CallCount);
    }

    [Fact]
    public async Task A_non_image_reference_is_rejected_before_calling_the_provider()
    {
        await using var db = NewDb();
        var store = new FakeAttachmentStore();
        var conversationId = Guid.NewGuid();
        var reference = new Attachment
        {
            FileName = "notes.txt",
            ContentType = "text/plain",
            SizeBytes = 1,
            Sha256 = "x",
            ConversationId = conversationId,
        };
        db.Attachments.Add(reference);
        await db.SaveChangesAsync();

        var client = new FakeImageGenerationClient();
        var context = Context(db, store, conversationId);
        var tool = new ImageGenerationTool(client, EnabledOptions(), context, NullLogger.Instance).Create();

        var result = await tool.InvokeAsync(new AIFunctionArguments
        {
            ["prompt"] = "a cat",
            ["referenceAttachmentIds"] = new[] { reference.Id },
        });

        Assert.Contains("not an image", AsText(result));
        Assert.Equal(0, client.CallCount);
    }

    [Fact]
    public async Task A_provider_failure_is_returned_to_the_model()
    {
        await using var db = NewDb();
        var store = new FakeAttachmentStore();
        var client = new FakeImageGenerationClient
        {
            ThrowOnCall = new ImageGenerationException("boom"),
        };

        var context = Context(db, store, Guid.NewGuid());
        var tool = new ImageGenerationTool(client, EnabledOptions(), context, NullLogger.Instance).Create();

        var result = await tool.InvokeAsync(new AIFunctionArguments { ["prompt"] = "a cat" });

        Assert.Contains("Image generation failed", AsText(result));
        Assert.Empty(await db.Attachments.ToListAsync());
    }

    [Fact]
    public void Generate_image_is_not_offered_when_disabled()
    {
        var factory = TurnToolFactory.CreateForTests(
            imageOptions: ImageGenerationOptions.FromConfig(new ProculConfig()));
        using var db = NewDb();
        var context = Context(db, new FakeAttachmentStore(), Guid.NewGuid());

        var names = factory.BuildTurnTools(context, McpTestHelpers.DisabledManager()).Select(t => t.Name).ToList();

        Assert.DoesNotContain("generate_image", names);
        Assert.Contains("show_image", names);
    }

    [Fact]
    public async Task A_generated_image_is_linked_to_the_assistant_message_and_streams_an_image_event()
    {
        await using var db = NewDb();
        var conversation = new Conversation { Title = "t" };
        db.Conversations.Add(conversation);
        await db.SaveChangesAsync();

        var store = new FakeAttachmentStore();
        var imageClient = new FakeImageGenerationClient();
        var factory = TurnToolFactory.CreateForTests(
            imageOptions: EnabledOptions(),
            imageClient: imageClient,
            urlPolicy: new PermissiveRemoteUrlPolicy());

        var service = new ChatStreamServiceV1(
            db,
            ChatModelTestHelpers.Registry(
                (ChatModelTestHelpers.Definition(capabilities: [ModelInputModality.Text]), InvokesGenerateImage())),
            new ModelUsageTracker(),
            new ProculConfig(),
            McpTestHelpers.DisabledManager(),
            store,
            TestAttachmentOptions.Create(),
            factory,
            NullLogger<ChatStreamServiceV1>.Instance);

        var events = new List<ChatStreamEventV1>();
        await foreach (var evt in service.StreamAssistantReplyAsync(
            conversation.Id, "draw a cat", [], new HashSet<ModelInputModality> { ModelInputModality.Text }, CancellationToken.None))
        {
            events.Add(evt);
        }

        var imageEvent = Assert.Single(events.OfType<ChatStreamEventV1.Image>());

        // The image was linked to the assistant reply, so it survives a reload.
        var assistant = await db.ConversationMessages.SingleAsync(m => m.MessageRole == MessageRole.Assistant);
        var attachment = await db.Attachments.SingleAsync(a => a.Id == imageEvent.Value.AttachmentId);
        Assert.Equal(assistant.Id, attachment.MessageId);
        Assert.Equal(conversation.Id, attachment.ConversationId);
        Assert.NotNull(store.Get(attachment.StorageKey));
    }

    /// <summary>
    /// A client whose streaming handler invokes the turn's <c>generate_image</c> tool through the
    /// same <see cref="AIFunction"/> the runtime would, then yields a short reply.
    /// </summary>
    private static FakeChatClient InvokesGenerateImage() => new(
        (_, _, _) => Task.FromResult(new ChatResponse(new ChatMessage(ChatRole.Assistant, "done"))),
        (_, options, ct) => InvokeAsync(options, ct));

    private static async IAsyncEnumerable<ChatResponseUpdate> InvokeAsync(
        ChatOptions? options,
        [EnumeratorCancellation] CancellationToken ct = default)
    {
        var tool = options?.Tools?.OfType<AIFunction>().FirstOrDefault(t => t.Name == "generate_image");
        if (tool is not null)
        {
            await tool.InvokeAsync(new AIFunctionArguments { ["prompt"] = "a cat" }, ct);
        }

        yield return new ChatResponseUpdate(ChatRole.Assistant, "done");
    }
}
