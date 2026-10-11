using Microsoft.EntityFrameworkCore;
using Procul.Api.Chat;
using Procul.Api.Chat.Models;
using Procul.Api.Infrastructure;

namespace Procul.Api.Attachments;

/// <summary>
/// The outcome of resolving a send request's attachment ids: either the loaded metadata entities
/// (to be attached to the persisted user message) or a user-facing error.
/// </summary>
internal sealed record AttachmentResolution(IReadOnlyList<Attachment> Attachments, string? Error)
{
    public bool IsValid => Error is null;

    public static AttachmentResolution Fail(string error) => new([], error);
}

/// <summary>
/// Loads and validates the attachment ids referenced by a create/send request, and enforces the
/// capability gate: a file whose type the selected model cannot read is a hard error (the client
/// is expected to gate in the UI too, but the backend is the source of truth).
/// </summary>
internal static class AttachmentGate
{
    public static async Task<AttachmentResolution> ResolveAsync(
        ProculDbContext db,
        ChatModelRegistry registry,
        ModelCatalogService catalog,
        IReadOnlyList<Guid>? attachmentIds,
        string? modelSlug,
        CancellationToken ct)
    {
        if (attachmentIds is not { Count: > 0 })
        {
            return new AttachmentResolution([], null);
        }

        var ids = attachmentIds.Distinct().ToList();
        var found = await db.Attachments
            .Where(a => ids.Contains(a.Id))
            .ToListAsync(ct);

        var missing = ids.Except(found.Select(a => a.Id)).ToList();
        if (missing.Count > 0)
        {
            return AttachmentResolution.Fail($"Unknown attachment id '{missing[0]}'.");
        }

        var alreadyAttached = found.FirstOrDefault(a => a.MessageId is not null);
        if (alreadyAttached is not null)
        {
            return AttachmentResolution.Fail(
                $"Attachment '{alreadyAttached.FileName}' is already attached to a message.");
        }

        var definition = registry.ResolveOrDefault(modelSlug);
        var capabilities = catalog.GetCapabilities(definition).Input;

        foreach (var attachment in found)
        {
            if (AttachmentContentBuilder.RequiredModality(attachment.ContentType) is { } required
                && !capabilities.Contains(required))
            {
                return AttachmentResolution.Fail(
                    $"The model '{definition.Name}' cannot read '{attachment.FileName}' " +
                    $"({attachment.ContentType}); it requires the " +
                    $"'{required.ToString().ToLowerInvariant()}' capability.");
            }
        }

        // Preserve the order the client sent.
        var ordered = ids.Select(id => found.First(a => a.Id == id)).ToList();
        return new AttachmentResolution(ordered, null);
    }
}
