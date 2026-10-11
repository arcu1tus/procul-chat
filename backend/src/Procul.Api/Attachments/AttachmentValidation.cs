namespace Procul.Api.Attachments;

/// <summary>Pure helpers for validating uploads and normalizing client-supplied file names.</summary>
public static class AttachmentValidation
{
    /// <summary>
    /// Whether <paramref name="contentType"/> matches one of the configured patterns. Patterns are
    /// exact MIME types (case-insensitive) or a top-level wildcard like <c>image/*</c>.
    /// </summary>
    public static bool IsAllowedContentType(string? contentType, IReadOnlyList<string> patterns)
    {
        var type = contentType?.Trim();
        if (string.IsNullOrEmpty(type))
        {
            return false;
        }

        foreach (var raw in patterns)
        {
            var pattern = raw.Trim();
            if (pattern.Length == 0)
            {
                continue;
            }

            if (pattern.EndsWith("/*", StringComparison.Ordinal))
            {
                // "image/*" -> prefix "image/"; keeps the declared top-level type only.
                if (type.StartsWith(pattern[..^1], StringComparison.OrdinalIgnoreCase))
                {
                    return true;
                }
            }
            else if (string.Equals(pattern, type, StringComparison.OrdinalIgnoreCase))
            {
                return true;
            }
        }

        return false;
    }

    /// <summary>
    /// Strips any directory component and control characters from a client-supplied file name so it
    /// can be stored and echoed in a <c>Content-Disposition</c> header safely.
    /// </summary>
    public static string SanitizeFileName(string? fileName, int maxLength = 512)
    {
        // Normalize both separators (the server is Linux, but clients may send Windows paths).
        var name = (fileName ?? string.Empty).Replace('\\', '/');
        var slash = name.LastIndexOf('/');
        if (slash >= 0)
        {
            name = name[(slash + 1)..];
        }

        name = new string(name.Where(character => !char.IsControl(character)).ToArray()).Trim();

        if (name.Length > maxLength)
        {
            name = name[..maxLength];
        }

        return string.IsNullOrWhiteSpace(name) ? "file" : name;
    }
}
