using Microsoft.EntityFrameworkCore;
using Procul.Api.Infrastructure;

namespace Procul.Api.Attachments;

/// <summary>
/// The default <see cref="IAttachmentStore"/>: bytes live in the <c>AttachmentBlobs</c> table
/// (<c>bytea</c>) keyed by the attachment id, so metadata queries never load a blob.
/// </summary>
public sealed class PostgresAttachmentStore(ProculDbContext db) : IAttachmentStore
{
    public string Kind => "postgres";

    public async Task<string> PutAsync(Attachment attachment, Stream content, CancellationToken ct)
    {
        using var buffer = new MemoryStream();
        await content.CopyToAsync(buffer, ct);

        // The blob's primary key is the attachment id; adding both to the same context (the
        // metadata was added by the caller) lets EF order the inserts and keep the FK satisfied.
        db.AttachmentBlobs.Add(new AttachmentBlob
        {
            AttachmentId = attachment.Id,
            Data = buffer.ToArray(),
        });

        return attachment.Id.ToString();
    }

    public async Task<Stream> OpenReadAsync(string storageKey, CancellationToken ct)
    {
        var id = ParseKey(storageKey);
        var blob = await db.AttachmentBlobs
            .AsNoTracking()
            .FirstOrDefaultAsync(b => b.AttachmentId == id, ct);

        if (blob is null)
        {
            throw new FileNotFoundException($"Attachment blob '{storageKey}' was not found.");
        }

        return new MemoryStream(blob.Data, writable: false);
    }

    public async Task DeleteAsync(string storageKey, CancellationToken ct)
    {
        if (!Guid.TryParse(storageKey, out var id))
        {
            return;
        }

        var blob = await db.AttachmentBlobs.FirstOrDefaultAsync(b => b.AttachmentId == id, ct);
        if (blob is not null)
        {
            db.AttachmentBlobs.Remove(blob);
        }
    }

    private static Guid ParseKey(string storageKey) =>
        Guid.TryParse(storageKey, out var id)
            ? id
            : throw new FileNotFoundException($"Attachment blob '{storageKey}' was not found.");
}
