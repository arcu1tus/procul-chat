using System.Net;
using System.Net.Http.Headers;
using Microsoft.EntityFrameworkCore;
using Microsoft.Extensions.AI;
using Microsoft.Extensions.Logging.Abstractions;
using Procul.Api.Attachments;
using Procul.Api.Chat.Tools;
using Procul.Api.Chat.V1;
using Procul.Api.Configuration;
using Procul.Api.Images;
using Procul.Api.Infrastructure;
using Procul.Api.Tests.Support;

namespace Procul.Api.Tests.Chat.Tools;

/// <summary>
/// Exercises the <c>show_image</c> tool: a URL is fetched through an <see cref="IHttpClientFactory"/>
/// (with an SSRF policy), base64 bytes are decoded, and both paths store the image and emit the
/// <c>image</c> event. Non-image and oversized responses are rejected.
/// </summary>
public class ShowImageToolTests
{
    private static readonly byte[] Png = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 1, 2, 3, 4];

    private static ProculDbContext NewDb() =>
        new(new DbContextOptionsBuilder<ProculDbContext>()
            .UseInMemoryDatabase($"showimage-{Guid.NewGuid():N}")
            .Options);

    private static ShowImageTool NewTool(
        ProculDbContext db,
        FakeAttachmentStore store,
        IHttpClientFactory factory,
        GeneratedMediaCollector? collector = null,
        long maxFileSizeBytes = 20 * 1024 * 1024) =>
        new(
            factory,
            new PermissiveRemoteUrlPolicy(),
            new TurnToolContext(
                db, store, TestAttachmentOptions.Create(maxFileSizeBytes: maxFileSizeBytes),
                Guid.NewGuid(), "test/model", collector ?? new GeneratedMediaCollector()),
            NullLogger.Instance);

    private static FakeHttpClientFactory Responder(HttpStatusCode status, byte[] bytes, string contentType) =>
        new(_ => new HttpResponseMessage(status)
        {
            Content = new ByteArrayContent(bytes)
            {
                Headers = { ContentType = new MediaTypeHeaderValue(contentType) },
            },
        });

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
    public async Task Fetches_a_url_stores_it_and_emits_an_image_event()
    {
        await using var db = NewDb();
        var store = new FakeAttachmentStore();
        var collector = new GeneratedMediaCollector();
        var tool = NewTool(db, store, Responder(HttpStatusCode.OK, Png, "image/png"), collector).Create();

        var result = await tool.InvokeAsync(new AIFunctionArguments { ["url"] = "https://images.test/cat.png" });

        Assert.Contains("Displayed the image", AsText(result));
        var stored = await db.Attachments.SingleAsync();
        Assert.Equal("image/png", stored.ContentType);
        Assert.Equal(Attachment.SourceGenerated, stored.Source);
        Assert.NotNull(store.Get(stored.StorageKey));
        Assert.True(collector.TryDequeueEvent(out var evt));
        Assert.IsType<ChatStreamEventV1.Image>(evt);
    }

    [Fact]
    public async Task Decodes_base64_with_a_data_prefix()
    {
        await using var db = NewDb();
        var store = new FakeAttachmentStore();
        var collector = new GeneratedMediaCollector();
        var tool = NewTool(db, store, Responder(HttpStatusCode.NotFound, [], "text/plain"), collector).Create();

        var data = "data:image/png;base64," + Convert.ToBase64String(Png);
        var result = await tool.InvokeAsync(new AIFunctionArguments { ["base64"] = data });

        Assert.Contains("Displayed the image", AsText(result));
        var stored = await db.Attachments.SingleAsync();
        Assert.Equal("image/png", stored.ContentType);
        Assert.NotNull(store.Get(stored.StorageKey));
    }

    [Fact]
    public async Task Rejects_a_url_that_is_not_an_image()
    {
        await using var db = NewDb();
        var store = new FakeAttachmentStore();
        var tool = NewTool(db, store, Responder(HttpStatusCode.OK, [1, 2, 3], "text/html")).Create();

        var result = await tool.InvokeAsync(new AIFunctionArguments { ["url"] = "https://images.test/page" });

        Assert.Contains("did not return an image", AsText(result));
        Assert.Empty(await db.Attachments.ToListAsync());
    }

    [Fact]
    public async Task Rejects_an_oversized_response()
    {
        await using var db = NewDb();
        var store = new FakeAttachmentStore();
        var tool = NewTool(db, store, Responder(HttpStatusCode.OK, Png, "image/png"), maxFileSizeBytes: 4).Create();

        var result = await tool.InvokeAsync(new AIFunctionArguments { ["url"] = "https://images.test/big.png" });

        Assert.Contains("size limit", AsText(result));
    }

    [Fact]
    public async Task Requires_exactly_one_source()
    {
        await using var db = NewDb();
        var store = new FakeAttachmentStore();
        var tool = NewTool(db, store, Responder(HttpStatusCode.OK, Png, "image/png")).Create();

        var neither = await tool.InvokeAsync(new AIFunctionArguments { ["fileName"] = "x.png" });
        var both = await tool.InvokeAsync(new AIFunctionArguments
        {
            ["url"] = "https://images.test/a.png",
            ["base64"] = Convert.ToBase64String(Png),
        });

        Assert.Contains("exactly one", AsText(neither));
        Assert.Contains("exactly one", AsText(both));
    }

    [Fact]
    public async Task Rejects_an_oversized_base64_payload_before_decoding()
    {
        await using var db = NewDb();
        var store = new FakeAttachmentStore();
        var tool = NewTool(db, store, Responder(HttpStatusCode.NotFound, [], "text/plain"), maxFileSizeBytes: 4).Create();

        var data = "data:image/png;base64," + Convert.ToBase64String(new byte[64]);
        var result = await tool.InvokeAsync(new AIFunctionArguments { ["base64"] = data });

        Assert.Contains("size limit", AsText(result));
        Assert.Empty(await db.Attachments.ToListAsync());
    }

    [Fact]
    public async Task Rejects_a_non_image_base64_payload()
    {
        await using var db = NewDb();
        var store = new FakeAttachmentStore();
        var tool = NewTool(db, store, Responder(HttpStatusCode.NotFound, [], "text/plain")).Create();

        var data = "data:text/plain;base64," +
                   Convert.ToBase64String(System.Text.Encoding.UTF8.GetBytes("hello world"));
        var result = await tool.InvokeAsync(new AIFunctionArguments { ["base64"] = data });

        Assert.Contains("not an image", AsText(result));
        Assert.Empty(await db.Attachments.ToListAsync());
    }

    [Fact]
    public async Task Rejects_a_non_http_scheme()
    {
        await using var db = NewDb();
        var store = new FakeAttachmentStore();
        var tool = NewTool(db, store, Responder(HttpStatusCode.OK, Png, "image/png")).Create();

        var result = await tool.InvokeAsync(new AIFunctionArguments { ["url"] = "file:///etc/passwd" });

        Assert.Contains("Could not display the image", AsText(result));
    }
}
