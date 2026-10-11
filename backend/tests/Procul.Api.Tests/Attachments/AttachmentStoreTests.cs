using Microsoft.EntityFrameworkCore;
using Microsoft.Extensions.Logging.Abstractions;
using Procul.Api.Attachments;
using Procul.Api.Infrastructure;
using Procul.Api.Tests.Support;

namespace Procul.Api.Tests.Attachments;

/// <summary>
/// The <see cref="IAttachmentStore"/> contract, exercised against both implementations: the
/// Postgres store over the in-memory EF provider (metadata + bytes) and the S3 store over a fake
/// <see cref="IS3Operations"/> seam. No database or network is touched.
/// </summary>
public class AttachmentStoreTests
{
    private static ProculDbContext NewDb() =>
        new(new DbContextOptionsBuilder<ProculDbContext>()
            .UseInMemoryDatabase($"attachments-{Guid.NewGuid():N}")
            .Options);

    private static Attachment NewAttachment(string fileName = "note.txt", string contentType = "text/plain") =>
        new() { FileName = fileName, ContentType = contentType, SizeBytes = 5, Sha256 = "abc" };

    [Fact]
    public async Task Postgres_store_round_trips_bytes_and_reports_its_kind()
    {
        await using var db = NewDb();
        var store = new PostgresAttachmentStore(db);
        var attachment = NewAttachment();

        db.Attachments.Add(attachment);
        attachment.StorageKey = await store.PutAsync(attachment, new MemoryStream("hello"u8.ToArray()), CancellationToken.None);
        await db.SaveChangesAsync();

        Assert.Equal("postgres", store.Kind);

        await using var stream = await store.OpenReadAsync(attachment.StorageKey, CancellationToken.None);
        using var reader = new StreamReader(stream);
        Assert.Equal("hello", await reader.ReadToEndAsync());
    }

    [Fact]
    public async Task Postgres_store_throws_for_a_missing_key()
    {
        await using var db = NewDb();
        var store = new PostgresAttachmentStore(db);

        await Assert.ThrowsAsync<FileNotFoundException>(
            () => store.OpenReadAsync(Guid.NewGuid().ToString(), CancellationToken.None));
    }

    [Fact]
    public async Task Postgres_store_delete_is_idempotent()
    {
        await using var db = NewDb();
        var store = new PostgresAttachmentStore(db);
        var attachment = NewAttachment();

        db.Attachments.Add(attachment);
        attachment.StorageKey = await store.PutAsync(attachment, new MemoryStream("x"u8.ToArray()), CancellationToken.None);
        await db.SaveChangesAsync();

        await store.DeleteAsync(attachment.StorageKey, CancellationToken.None);
        await db.SaveChangesAsync();
        Assert.Empty(db.AttachmentBlobs);

        // Deleting again (or a totally unknown key) is a no-op.
        await store.DeleteAsync(attachment.StorageKey, CancellationToken.None);
        await store.DeleteAsync("not-a-guid", CancellationToken.None);
    }

    [Fact]
    public async Task S3_store_round_trips_bytes_and_reports_its_kind()
    {
        var store = new S3AttachmentStore(new FakeS3Operations());
        var attachment = NewAttachment();

        var key = await store.PutAsync(attachment, new MemoryStream("hello"u8.ToArray()), CancellationToken.None);

        Assert.Equal("s3", store.Kind);
        Assert.Equal($"attachments/{attachment.Id:N}", key);

        await using var stream = await store.OpenReadAsync(key, CancellationToken.None);
        using var reader = new StreamReader(stream);
        Assert.Equal("hello", await reader.ReadToEndAsync());
    }

    [Fact]
    public async Task S3_store_delete_is_idempotent_and_missing_key_throws()
    {
        var operations = new FakeS3Operations();
        var store = new S3AttachmentStore(operations);

        await store.DeleteAsync("attachments/missing", CancellationToken.None);
        await store.DeleteAsync("attachments/missing", CancellationToken.None);

        await Assert.ThrowsAsync<FileNotFoundException>(
            () => store.OpenReadAsync("attachments/missing", CancellationToken.None));
    }

    /// <summary>An in-memory <see cref="IS3Operations"/> used as the S3 seam in tests.</summary>
    private sealed class FakeS3Operations : IS3Operations
    {
        private readonly Dictionary<string, byte[]> _objects = new(StringComparer.Ordinal);

        public Task PutAsync(string key, Stream content, string contentType, CancellationToken ct)
        {
            using var buffer = new MemoryStream();
            content.CopyTo(buffer);
            _objects[key] = buffer.ToArray();
            return Task.CompletedTask;
        }

        public Task<Stream> OpenReadAsync(string key, CancellationToken ct) =>
            _objects.TryGetValue(key, out var data)
                ? Task.FromResult<Stream>(new MemoryStream(data, writable: false))
                : Task.FromException<Stream>(new FileNotFoundException(key));

        public Task DeleteAsync(string key, CancellationToken ct)
        {
            _objects.Remove(key);
            return Task.CompletedTask;
        }
    }
}
