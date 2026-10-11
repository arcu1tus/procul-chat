using Procul.Api.Attachments;

namespace Procul.Api.Tests.Support;

/// <summary>An in-memory <see cref="IAttachmentStore"/> so tests never touch Postgres or S3.</summary>
internal sealed class FakeAttachmentStore : IAttachmentStore
{
    private readonly Dictionary<string, byte[]> _byKey = new(StringComparer.Ordinal);

    public string Kind => "fake";

    public int Count => _byKey.Count;

    public Task<string> PutAsync(Attachment attachment, Stream content, CancellationToken ct)
    {
        using var buffer = new MemoryStream();
        content.CopyTo(buffer);
        var key = attachment.Id.ToString();
        _byKey[key] = buffer.ToArray();
        return Task.FromResult(key);
    }

    public Task<Stream> OpenReadAsync(string storageKey, CancellationToken ct) =>
        _byKey.TryGetValue(storageKey, out var data)
            ? Task.FromResult<Stream>(new MemoryStream(data, writable: false))
            : Task.FromException<Stream>(new FileNotFoundException(storageKey));

    public Task DeleteAsync(string storageKey, CancellationToken ct)
    {
        _byKey.Remove(storageKey);
        return Task.CompletedTask;
    }

    public byte[]? Get(string storageKey) => _byKey.TryGetValue(storageKey, out var data) ? data : null;
}
