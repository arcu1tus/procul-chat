using System.Security.Cryptography;
using Procul.Api.Attachments;
using Procul.Api.Chat.V1;

namespace Procul.Api.Chat.Tools;

/// <summary>
/// Shared persistence for media created by a tool (<c>generate_image</c> / <c>show_image</c>):
/// stores the bytes through <see cref="IAttachmentStore"/> as a new <see cref="Attachment"/> row
/// marked <see cref="Attachment.SourceGenerated"/>, and enqueues the <c>image</c> SSE event. The
/// assistant-message link is applied later by the reply core.
/// </summary>
internal static class ToolMedia
{
    public static async Task<Attachment> StoreAsync(
        TurnToolContext context,
        byte[] bytes,
        string fileName,
        string contentType,
        CancellationToken ct)
    {
        var attachment = new Attachment
        {
            FileName = fileName,
            ContentType = contentType,
            SizeBytes = bytes.Length,
            Sha256 = Convert.ToHexStringLower(SHA256.HashData(bytes)),
            Source = Attachment.SourceGenerated,
            ConversationId = context.ConversationId,
        };

        // Add the metadata first so the Postgres store's blob FK is satisfied; PutAsync returns the
        // storage key for both implementations.
        context.Db.Attachments.Add(attachment);
        try
        {
            attachment.StorageKey = await context.Store.PutAsync(attachment, new MemoryStream(bytes), ct);
            await context.Db.SaveChangesAsync(ct);
        }
        catch
        {
            // Don't leave a half-persisted (keyless) row tracked for the reply's later save to
            // insert. The tool turns the exception into a message; the caller rethrows only a
            // cancellation.
            context.Db.Entry(attachment).State = Microsoft.EntityFrameworkCore.EntityState.Detached;
            throw;
        }

        context.Media.AddImage(
            attachment,
            new ChatStreamEventV1.Image(new ChatStreamImageV1(
                attachment.Id, attachment.FileName, attachment.ContentType)));

        return attachment;
    }
}
