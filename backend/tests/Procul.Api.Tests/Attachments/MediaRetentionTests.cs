using Microsoft.EntityFrameworkCore;
using Microsoft.Extensions.Logging.Abstractions;
using Procul.Api.Attachments;
using Procul.Api.Infrastructure;
using Procul.Api.Tests.Support;

namespace Procul.Api.Tests.Attachments;

/// <summary>
/// The retention sweep: after the window, orphaned media (uploads and generated images) is deleted
/// outright, referenced media keeps its metadata but loses its bytes, and a <c>"0"</c> window
/// disables retention for its category. Media inside the window is never touched.
/// </summary>
public class MediaRetentionTests
{
    private static ProculDbContext NewDb() =>
        new(new DbContextOptionsBuilder<ProculDbContext>()
            .UseInMemoryDatabase($"retention-{Guid.NewGuid():N}")
            .Options);

    private static MediaRetentionService Service(TimeSpan upload, TimeSpan generated) =>
        new(
            null!,
            new MediaRetentionOptions
            {
                UploadRetention = upload,
                GeneratedRetention = generated,
                Interval = TimeSpan.FromHours(1),
                InitialDelay = TimeSpan.Zero,
            },
            NullLogger<MediaRetentionService>.Instance);

    private static async Task<Attachment> SeedAsync(
        ProculDbContext db,
        FakeAttachmentStore store,
        string source,
        DateTimeOffset createdAt,
        Guid? messageId = null)
    {
        var attachment = new Attachment
        {
            FileName = $"{source}.png",
            ContentType = "image/png",
            SizeBytes = 3,
            Sha256 = "x",
            Source = source,
            CreatedAt = createdAt,
            MessageId = messageId,
        };

        db.Attachments.Add(attachment);
        await db.SaveChangesAsync();
        attachment.StorageKey = await store.PutAsync(
            attachment, new MemoryStream([1, 2, 3]), CancellationToken.None);
        await db.SaveChangesAsync();
        return attachment;
    }

    private static readonly TimeSpan Window = TimeSpan.FromDays(14);
    private static readonly DateTimeOffset Now = DateTimeOffset.UtcNow;

    [Fact]
    public async Task Orphaned_uploads_are_deleted_metadata_and_bytes()
    {
        await using var db = NewDb();
        var store = new FakeAttachmentStore();
        var attachment = await SeedAsync(db, store, Attachment.SourceUpload, Now.AddDays(-20));

        await Service(Window, Window).PurgeAsync(db, store, Now, CancellationToken.None);

        Assert.Null(await db.Attachments.FirstOrDefaultAsync(a => a.Id == attachment.Id));
        Assert.Null(store.Get(attachment.StorageKey));
    }

    [Fact]
    public async Task Referenced_uploads_keep_their_row_but_lose_their_bytes()
    {
        await using var db = NewDb();
        var store = new FakeAttachmentStore();
        var messageId = Guid.NewGuid();
        var attachment = await SeedAsync(db, store, Attachment.SourceUpload, Now.AddDays(-20), messageId);

        await Service(Window, Window).PurgeAsync(db, store, Now, CancellationToken.None);

        var row = await db.Attachments.FirstOrDefaultAsync(a => a.Id == attachment.Id);
        Assert.NotNull(row);
        Assert.Equal(messageId, row!.MessageId);
        Assert.Null(store.Get(attachment.StorageKey));
    }

    [Fact]
    public async Task Generated_images_use_their_own_window()
    {
        await using var db = NewDb();
        var store = new FakeAttachmentStore();
        var generated = await SeedAsync(db, store, Attachment.SourceGenerated, Now.AddDays(-10));

        // Uploads keep 14d, but generated images expire after 7d.
        await Service(TimeSpan.FromDays(14), TimeSpan.FromDays(7)).PurgeAsync(db, store, Now, CancellationToken.None);

        Assert.Null(await db.Attachments.FirstOrDefaultAsync(a => a.Id == generated.Id));
        Assert.Null(store.Get(generated.StorageKey));
    }

    [Fact]
    public async Task Media_inside_the_window_is_untouched()
    {
        await using var db = NewDb();
        var store = new FakeAttachmentStore();
        var recent = await SeedAsync(db, store, Attachment.SourceUpload, Now.AddDays(-2));

        await Service(Window, Window).PurgeAsync(db, store, Now, CancellationToken.None);

        Assert.NotNull(await db.Attachments.FirstOrDefaultAsync(a => a.Id == recent.Id));
        Assert.NotNull(store.Get(recent.StorageKey));
    }

    [Fact]
    public async Task A_zero_window_disables_retention()
    {
        await using var db = NewDb();
        var store = new FakeAttachmentStore();
        var old = await SeedAsync(db, store, Attachment.SourceUpload, Now.AddDays(-100));
        var oldGenerated = await SeedAsync(db, store, Attachment.SourceGenerated, Now.AddDays(-100));

        await Service(TimeSpan.Zero, TimeSpan.Zero).PurgeAsync(db, store, Now, CancellationToken.None);

        Assert.NotNull(await db.Attachments.FirstOrDefaultAsync(a => a.Id == old.Id));
        Assert.NotNull(await db.Attachments.FirstOrDefaultAsync(a => a.Id == oldGenerated.Id));
        Assert.NotNull(store.Get(old.StorageKey));
        Assert.NotNull(store.Get(oldGenerated.StorageKey));
    }
}
