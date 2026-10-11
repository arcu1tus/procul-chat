using System.Net;
using Amazon;
using Amazon.Runtime;
using Amazon.S3;
using Amazon.S3.Model;
using Procul.Api.Configuration;

namespace Procul.Api.Attachments;

/// <summary>
/// The object operations <see cref="S3AttachmentStore"/> needs. Implemented over the AWS SDK by
/// <see cref="AmazonS3Operations"/>; a thin seam so the store's contract is testable without a
/// fake for the whole (very large) <see cref="IAmazonS3"/> interface.
/// </summary>
internal interface IS3Operations
{
    Task PutAsync(string key, Stream content, string contentType, CancellationToken ct);

    /// <exception cref="FileNotFoundException">The key does not exist.</exception>
    Task<Stream> OpenReadAsync(string key, CancellationToken ct);

    /// <summary>Deletes the object. A missing key is a no-op.</summary>
    Task DeleteAsync(string key, CancellationToken ct);
}

/// <summary>The AWS SDK implementation of <see cref="IS3Operations"/> for one bucket.</summary>
internal sealed class AmazonS3Operations(IAmazonS3 s3, string bucket, ILogger logger) : IS3Operations
{
    public Task PutAsync(string key, Stream content, string contentType, CancellationToken ct) =>
        s3.PutObjectAsync(new PutObjectRequest
        {
            BucketName = bucket,
            Key = key,
            InputStream = content,
            ContentType = contentType,
            AutoCloseStream = false,
        }, ct);

    public async Task<Stream> OpenReadAsync(string key, CancellationToken ct)
    {
        try
        {
            var response = await s3.GetObjectAsync(bucket, key, ct);
            return response.ResponseStream;
        }
        catch (AmazonS3Exception ex) when (ex.StatusCode == HttpStatusCode.NotFound)
        {
            throw new FileNotFoundException($"Attachment blob '{key}' was not found.", ex);
        }
    }

    public async Task DeleteAsync(string key, CancellationToken ct)
    {
        try
        {
            await s3.DeleteObjectAsync(bucket, key, ct);
        }
        catch (AmazonS3Exception ex) when (ex.StatusCode == HttpStatusCode.NotFound)
        {
            // Idempotent: already gone.
        }
        catch (Exception ex)
        {
            // Best-effort: a failed delete must not fail the request; the metadata row is removed
            // regardless.
            logger.LogWarning(ex, "Could not delete attachment object '{Key}' from S3.", key);
        }
    }
}

/// <summary>
/// An S3-compatible <see cref="IAttachmentStore"/> (AWS S3 or MinIO via <c>serviceUrl</c> +
/// <c>forcePathStyle</c>). Credentials come from the config when supplied, otherwise the AWS
/// default credential chain.
/// </summary>
public sealed class S3AttachmentStore : IAttachmentStore
{
    private readonly IS3Operations _operations;

    /// <summary>The DI constructor: the AWS SDK client comes from DI (a singleton).</summary>
    public S3AttachmentStore(
        IAmazonS3 s3,
        AttachmentOptions options,
        ILogger<S3AttachmentStore> logger)
        : this(new AmazonS3Operations(s3, ResolveBucket(options), logger))
    {
    }

    /// <summary>The test seam: object operations are supplied directly.</summary>
    internal S3AttachmentStore(IS3Operations operations) => _operations = operations;

    public string Kind => "s3";

    public async Task<string> PutAsync(Attachment attachment, Stream content, CancellationToken ct)
    {
        var key = BuildKey(attachment);
        await _operations.PutAsync(key, content, attachment.ContentType, ct);
        return key;
    }

    public Task<Stream> OpenReadAsync(string storageKey, CancellationToken ct) =>
        _operations.OpenReadAsync(storageKey, ct);

    public Task DeleteAsync(string storageKey, CancellationToken ct) =>
        _operations.DeleteAsync(storageKey, ct);

    /// <summary>The object key for an attachment: <c>attachments/{id}</c>.</summary>
    internal static string BuildKey(Attachment attachment) => $"attachments/{attachment.Id:N}";

    private static string ResolveBucket(AttachmentOptions options) =>
        options.S3?.Bucket is { Length: > 0 } bucket
            ? bucket
            : throw new AttachmentStoreException(
                "attachments.s3.bucket is required when attachments.storage is 's3'.");

    /// <summary>Builds the S3 client from the validated config, or throws when it is incomplete.</summary>
    internal static IAmazonS3 CreateClient(AttachmentOptions options)
    {
        var s3 = options.S3
            ?? throw new AttachmentStoreException(
                "attachments.storage is 's3' but no 'attachments.s3' section is configured.");

        var config = new AmazonS3Config();
        if (!string.IsNullOrWhiteSpace(s3.ServiceUrl))
        {
            config.ServiceURL = s3.ServiceUrl;
            config.ForcePathStyle = s3.ForcePathStyle;
        }
        else if (!string.IsNullOrWhiteSpace(s3.Region))
        {
            config.RegionEndpoint = RegionEndpoint.GetBySystemName(s3.Region);
        }

        return !string.IsNullOrWhiteSpace(s3.AccessKey) && !string.IsNullOrWhiteSpace(s3.SecretKey)
            ? new AmazonS3Client(new BasicAWSCredentials(s3.AccessKey, s3.SecretKey), config)
            : new AmazonS3Client(config);
    }
}
