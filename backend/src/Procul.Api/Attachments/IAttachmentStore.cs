namespace Procul.Api.Attachments;

/// <summary>
/// Stores and retrieves attachment bytes behind a configurable backend
/// (<c>attachments.storage</c>: <c>postgres</c> or <c>s3</c>). Metadata always lives in Postgres;
/// only the bytes go through this seam.
///
/// <para>
/// The interface is deliberately byte-oriented so both implementations share the same contract
/// tests. <see cref="DeleteAsync"/> is best-effort and idempotent: deleting a missing key is a
/// no-op.
/// </para>
/// </summary>
public interface IAttachmentStore
{
    /// <summary><c>postgres</c> or <c>s3</c>.</summary>
    string Kind { get; }

    /// <summary>
    /// Stores the bytes for <paramref name="attachment"/> and returns the storage key. The caller
    /// already attached the metadata entity to its <c>DbContext</c>; the Postgres implementation
    /// adds the blob row to the same context (saved by the caller) and returns the attachment id.
    /// </summary>
    Task<string> PutAsync(Attachment attachment, Stream content, CancellationToken ct);

    /// <summary>Opens the stored bytes for reading.</summary>
    /// <exception cref="FileNotFoundException">The key does not exist in the store.</exception>
    Task<Stream> OpenReadAsync(string storageKey, CancellationToken ct);

    /// <summary>Deletes the stored bytes. Missing keys are ignored.</summary>
    Task DeleteAsync(string storageKey, CancellationToken ct);
}

/// <summary>The configured store could not be created (e.g. S3 without a bucket).</summary>
public sealed class AttachmentStoreException(string message) : Exception(message);
