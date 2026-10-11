using System.Text.RegularExpressions;

namespace Procul.Api.Mcp;

/// <summary>
/// Builds the function names exposed to the model for MCP tools. OpenAI-compatible function
/// names must match <c>^[a-zA-Z0-9_-]{1,64}$</c> and be unique across built-ins and every
/// server, so each tool is namespaced <c>{server}__{tool}</c>, sanitized, truncated and, on
/// collision, suffixed.
/// </summary>
internal static partial class McpToolNaming
{
    /// <summary>Maximum length of an OpenAI function name.</summary>
    public const int MaxNameLength = 64;

    /// <summary>Separator between the server and tool segments.</summary>
    public const string Separator = "__";

    [GeneratedRegex("[^a-zA-Z0-9_-]")]
    private static partial Regex InvalidCharacters();

    /// <summary>Replaces every character outside <c>[a-zA-Z0-9_-]</c> with <c>_</c>.</summary>
    public static string Sanitize(string raw) => InvalidCharacters().Replace(raw, "_");

    /// <summary>
    /// The un-deduplicated name for a tool: <c>{server}__{tool}</c>, both segments sanitized and
    /// the whole thing capped at <see cref="MaxNameLength"/>.
    /// </summary>
    public static string Qualify(string server, string tool)
    {
        var name = $"{Sanitize(server)}{Separator}{Sanitize(tool)}";
        return name.Length > MaxNameLength ? name[..MaxNameLength] : name;
    }
}

/// <summary>
/// Assigns collision-free names within one tool snapshot. Each instance tracks the names it has
/// already handed out, so a second tool with the same qualified name gets <c>_2</c>, <c>_3</c>, …
/// </summary>
internal sealed class McpToolNameAssigner
{
    private readonly HashSet<string> _used = new(StringComparer.Ordinal);

    /// <summary>Reserves and returns a unique, sanitized, ≤64-character name.</summary>
    public string Assign(string server, string tool)
    {
        var baseName = McpToolNaming.Qualify(server, tool);
        if (baseName.Length == 0)
        {
            baseName = "tool";
        }

        if (_used.Add(baseName))
        {
            return baseName;
        }

        for (var suffix = 2; ; suffix++)
        {
            var suffixText = $"_{suffix}";
            var maxBase = McpToolNaming.MaxNameLength - suffixText.Length;
            var candidate = (baseName.Length > maxBase ? baseName[..maxBase] : baseName) + suffixText;
            if (_used.Add(candidate))
            {
                return candidate;
            }
        }
    }
}
