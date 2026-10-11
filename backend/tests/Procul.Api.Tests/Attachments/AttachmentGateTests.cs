using Microsoft.EntityFrameworkCore;
using Procul.Api.Attachments;
using Procul.Api.Chat;
using Procul.Api.Infrastructure;
using Procul.Api.Tests.Support;

namespace Procul.Api.Tests.Attachments;

/// <summary>
/// Resolving a send request's attachment ids: unknown ids, already-attached ids, and the
/// capability gate (a file the selected model cannot read is rejected by name).
/// </summary>
public class AttachmentGateTests
{
    private static ProculDbContext NewDb() =>
        new(new DbContextOptionsBuilder<ProculDbContext>()
            .UseInMemoryDatabase($"gate-{Guid.NewGuid():N}")
            .Options);

    private static ChatModelRegistry Registry(params ModelInputModality[] capabilities) =>
        ChatModelTestHelpers.Registry(
            (ChatModelTestHelpers.Definition(capabilities: capabilities), new FakeChatClient("ok")));

    private static Attachment Seed(ProculDbContext db, string fileName, string contentType)
    {
        var attachment = new Attachment
        {
            FileName = fileName,
            ContentType = contentType,
            SizeBytes = 3,
            Sha256 = "x",
            StorageKey = "k",
        };
        db.Attachments.Add(attachment);
        db.SaveChanges();
        return attachment;
    }

    [Fact]
    public async Task No_ids_resolves_to_an_empty_ok_result()
    {
        await using var db = NewDb();
        var registry = Registry(ModelInputModality.Text, ModelInputModality.Image);

        var result = await AttachmentGate.ResolveAsync(
            db, registry, ChatModelTestHelpers.Catalog(registry), null, null, CancellationToken.None);

        Assert.True(result.IsValid);
        Assert.Empty(result.Attachments);
    }

    [Fact]
    public async Task An_unknown_id_is_rejected()
    {
        await using var db = NewDb();
        var registry = Registry(ModelInputModality.Text, ModelInputModality.Image);

        var result = await AttachmentGate.ResolveAsync(
            db, registry, ChatModelTestHelpers.Catalog(registry),
            [Guid.NewGuid()], null, CancellationToken.None);

        Assert.False(result.IsValid);
        Assert.Contains("Unknown attachment id", result.Error);
    }

    [Fact]
    public async Task An_already_attached_id_is_rejected()
    {
        await using var db = NewDb();
        var registry = Registry(ModelInputModality.Text, ModelInputModality.Image);
        var attachment = Seed(db, "cat.png", "image/png");
        attachment.MessageId = Guid.NewGuid(); // pretend it is already on a message
        await db.SaveChangesAsync();

        var result = await AttachmentGate.ResolveAsync(
            db, registry, ChatModelTestHelpers.Catalog(registry),
            [attachment.Id], null, CancellationToken.None);

        Assert.False(result.IsValid);
        Assert.Contains("already attached", result.Error);
    }

    [Fact]
    public async Task An_unsupported_type_is_rejected_with_the_file_and_capability()
    {
        await using var db = NewDb();
        var registry = Registry(ModelInputModality.Text); // image NOT supported
        var attachment = Seed(db, "cat.png", "image/png");

        var result = await AttachmentGate.ResolveAsync(
            db, registry, ChatModelTestHelpers.Catalog(registry),
            [attachment.Id], null, CancellationToken.None);

        Assert.False(result.IsValid);
        Assert.Contains("cat.png", result.Error);
        Assert.Contains("image", result.Error);
    }

    [Fact]
    public async Task A_supported_type_resolves_in_request_order()
    {
        await using var db = NewDb();
        var registry = Registry(ModelInputModality.Text, ModelInputModality.Image);
        var first = Seed(db, "a.png", "image/png");
        var second = Seed(db, "b.png", "image/png");

        var result = await AttachmentGate.ResolveAsync(
            db, registry, ChatModelTestHelpers.Catalog(registry),
            [second.Id, first.Id], null, CancellationToken.None);

        Assert.True(result.IsValid);
        Assert.Equal([second.Id, first.Id], result.Attachments.Select(a => a.Id));
    }

    [Fact]
    public async Task A_video_is_never_gated_even_without_the_video_capability()
    {
        await using var db = NewDb();
        var registry = Registry(ModelInputModality.Text);
        var attachment = Seed(db, "movie.mp4", "video/mp4");

        var result = await AttachmentGate.ResolveAsync(
            db, registry, ChatModelTestHelpers.Catalog(registry),
            [attachment.Id], null, CancellationToken.None);

        Assert.True(result.IsValid);
    }
}
