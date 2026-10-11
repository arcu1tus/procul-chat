using System.Text;
using Microsoft.Extensions.AI;
using Procul.Api.Chat;

namespace Procul.Api.Attachments;

/// <summary>
/// Maps an attachment to the <see cref="AIContent"/> parts the model receives. Pure and
/// side-effect-free (bytes are supplied by the caller), so every row of the mapping table is
/// unit-testable.
///
/// <para>
/// The OpenAI adapter understands image <see cref="DataContent"/>, <c>application/pdf</c>
/// <see cref="DataContent"/> (a file part), and <c>audio/mpeg</c>/<c>audio/wav</c>
/// <see cref="DataContent"/> (input audio). Everything else — notably video — is dropped by the
/// adapter, so this builder emits a short text placeholder instead of wasting bytes.
/// </para>
/// </summary>
public static class AttachmentContentBuilder
{
    private static readonly HashSet<string> AudioTypes = new(StringComparer.OrdinalIgnoreCase)
    {
        "audio/mpeg",
        "audio/mp3",
        "audio/wav",
        "audio/x-wav",
        "audio/wave",
    };

    /// <summary>
    /// The input modality a content type needs in order to be sent, or null when the type is
    /// always handled (text) or never sent (unknown types, video). Used for capability gating.
    /// </summary>
    public static ModelInputModality? RequiredModality(string contentType)
    {
        var type = contentType.Trim();

        if (type.StartsWith("image/", StringComparison.OrdinalIgnoreCase))
        {
            return ModelInputModality.Image;
        }

        if (string.Equals(type, "application/pdf", StringComparison.OrdinalIgnoreCase))
        {
            return ModelInputModality.Pdf;
        }

        if (AudioTypes.Contains(type))
        {
            return ModelInputModality.Audio;
        }

        return null;
    }

    /// <summary>Whether a model with these capabilities can receive the given content type.</summary>
    public static bool IsSupported(string contentType, IReadOnlySet<ModelInputModality> capabilities) =>
        RequiredModality(contentType) is not { } required || capabilities.Contains(required);

    /// <summary>Whether the content type is a <c>text/*</c> file that is inlined into the prompt.</summary>
    public static bool IsText(string contentType) =>
        contentType.Trim().StartsWith("text/", StringComparison.OrdinalIgnoreCase);

    /// <summary>A short, model-readable description of an attachment.</summary>
    public static string Describe(string fileName, string contentType, long sizeBytes) =>
        $"[Attached file: {fileName} ({contentType}, {sizeBytes} bytes)]";

    /// <summary>The note emitted for an attachment that is not sent to the model this turn.</summary>
    public static TextContent NotSentNote(Attachment attachment) =>
        new($"{Describe(attachment.FileName, attachment.ContentType, attachment.SizeBytes)} — not sent to this model");

    /// <summary>The note emitted for an earlier turn's attachment when history is not re-sent.</summary>
    public static TextContent HistoryNote(Attachment attachment) =>
        new(Describe(attachment.FileName, attachment.ContentType, attachment.SizeBytes));

    /// <summary>
    /// Builds the parts for one attachment. Callers must only pass bytes when the attachment is
    /// actually sent (see <see cref="IsSupported"/>); when the model cannot read the type, a
    /// placeholder is produced instead.
    /// </summary>
    public static IReadOnlyList<AIContent> Build(
        Attachment attachment,
        ReadOnlyMemory<byte> bytes,
        IReadOnlySet<ModelInputModality> capabilities,
        long textInlineMaxBytes)
    {
        var type = attachment.ContentType;

        if (!IsSupported(type, capabilities))
        {
            return [NotSentNote(attachment)];
        }

        if (type.StartsWith("image/", StringComparison.OrdinalIgnoreCase))
        {
            return [new DataContent(bytes, type)];
        }

        if (string.Equals(type, "application/pdf", StringComparison.OrdinalIgnoreCase))
        {
            return [new DataContent(bytes, "application/pdf") { Name = attachment.FileName }];
        }

        if (AudioTypes.Contains(type))
        {
            return [new DataContent(bytes, type)];
        }

        if (IsText(type))
        {
            var length = (int)Math.Clamp(bytes.Length, 0, Math.Max(0, textInlineMaxBytes));
            var text = Encoding.UTF8.GetString(bytes.Span[..length]);
            return [new TextContent($"--- file: {attachment.FileName} ---\n{text}")];
        }

        // Video and any other unsupported type: stored and rendered, but never sent.
        return [NotSentNote(attachment)];
    }
}
