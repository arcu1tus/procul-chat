using System.Security.Cryptography;
using Microsoft.AspNetCore.Http.HttpResults;
using Microsoft.EntityFrameworkCore;
using Microsoft.Net.Http.Headers;
using Procul.Api.Attachments.V1;
using Procul.Api.Configuration;
using Procul.Api.Infrastructure;

namespace Procul.Api.Attachments;

/// <summary>
/// The attachment surface: upload a file, stream its bytes back, and delete it. All routes are
/// authenticated like the rest of <c>/v1</c>. There are no users, so any authenticated client can
/// read any attachment id (a hardening follow-up).
/// </summary>
internal static class AttachmentEndpointsV1
{
    public static RouteGroupBuilder MapAttachmentsV1(this RouteGroupBuilder group)
    {
        // IFormFile binding opts into antiforgery by default; the API is bearer-token, cookie-less,
        // so there is no CSRF surface to protect.
        group.MapPost("/", UploadAsync).DisableAntiforgery();
        group.MapGet("/{id:guid}", DownloadAsync);
        group.MapDelete("/{id:guid}", DeleteAsync);
        return group;
    }

    /// <summary>Accepts a multipart <c>file</c> field, stores the bytes, and returns the metadata.</summary>
    private static async Task<Results<Created<AttachmentV1>, ProblemHttpResult>> UploadAsync(
        IFormFile file,
        ProculDbContext db,
        IAttachmentStore store,
        AttachmentOptions options,
        CancellationToken ct)
    {
        if (file is null || file.Length == 0)
        {
            return TypedResults.Problem(
                statusCode: StatusCodes.Status400BadRequest,
                detail: "A non-empty 'file' field is required.");
        }

        if (file.Length > options.MaxFileSizeBytes)
        {
            return TypedResults.Problem(
                statusCode: StatusCodes.Status413PayloadTooLarge,
                detail: $"'{file.FileName}' is {file.Length} bytes; the limit is {options.MaxFileSizeBytes} bytes.");
        }

        var contentType = string.IsNullOrWhiteSpace(file.ContentType)
            ? "application/octet-stream"
            : file.ContentType.Trim();

        if (!AttachmentValidation.IsAllowedContentType(contentType, options.AllowedContentTypes))
        {
            return TypedResults.Problem(
                statusCode: StatusCodes.Status400BadRequest,
                detail: $"Content type '{contentType}' is not allowed. " +
                    $"Allowed: {string.Join(", ", options.AllowedContentTypes)}.");
        }

        byte[] bytes;
        await using (var stream = file.OpenReadStream())
        {
            using var buffer = new MemoryStream((int)Math.Min(file.Length, 64 * 1024));
            await stream.CopyToAsync(buffer, ct);
            bytes = buffer.ToArray();
        }

        var attachment = new Attachment
        {
            FileName = AttachmentValidation.SanitizeFileName(file.FileName),
            ContentType = contentType,
            SizeBytes = bytes.Length,
            Sha256 = Convert.ToHexStringLower(SHA256.HashData(bytes)),
        };

        // Add the metadata first so the Postgres store's blob FK is satisfied; PutAsync returns the
        // storage key for both implementations.
        db.Attachments.Add(attachment);
        attachment.StorageKey = await store.PutAsync(attachment, new MemoryStream(bytes), ct);
        await db.SaveChangesAsync(ct);

        return TypedResults.Created($"/v1/attachments/{attachment.Id}", ToV1(attachment));
    }

    /// <summary>Streams the stored bytes with the stored content type and an inline disposition.</summary>
    private static async Task<Results<FileStreamHttpResult, NotFound, ProblemHttpResult>> DownloadAsync(
        Guid id,
        HttpResponse response,
        ProculDbContext db,
        IAttachmentStore store,
        CancellationToken ct)
    {
        var attachment = await db.Attachments
            .AsNoTracking()
            .FirstOrDefaultAsync(a => a.Id == id, ct);

        if (attachment is null)
        {
            return TypedResults.NotFound();
        }

        Stream stream;
        try
        {
            stream = await store.OpenReadAsync(attachment.StorageKey, ct);
        }
        catch (FileNotFoundException ex)
        {
            return TypedResults.Problem(
                statusCode: StatusCodes.Status404NotFound,
                detail: ex.Message);
        }

        // A web client reads the filename from Content-Disposition (the CORS policy exposes it).
        var disposition = new ContentDispositionHeaderValue("inline");
        disposition.SetHttpFileName(attachment.FileName);
        response.Headers.ContentDisposition = disposition.ToString();

        return TypedResults.File(stream, attachment.ContentType);
    }

    /// <summary>Deletes the metadata and best-effort deletes the bytes. Idempotent (always 204).</summary>
    private static async Task<NoContent> DeleteAsync(
        Guid id,
        ProculDbContext db,
        IAttachmentStore store,
        CancellationToken ct)
    {
        var attachment = await db.Attachments.FirstOrDefaultAsync(a => a.Id == id, ct);
        if (attachment is not null)
        {
            await store.DeleteAsync(attachment.StorageKey, ct);
            db.Attachments.Remove(attachment);
            await db.SaveChangesAsync(ct);
        }

        return TypedResults.NoContent();
    }

    /// <summary>Maps the entity to its DTO.</summary>
    public static AttachmentV1 ToV1(Attachment attachment) =>
        new(attachment.Id, attachment.FileName, attachment.ContentType, attachment.SizeBytes, attachment.CreatedAt);
}
