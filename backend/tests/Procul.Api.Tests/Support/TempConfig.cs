namespace Procul.Api.Tests.Support;

/// <summary>
/// Writes a temporary config file for a test and deletes it on dispose.
/// </summary>
internal sealed class TempConfig : IDisposable
{
    private TempConfig(string path) => Path = path;

    /// <summary>The absolute path of the written file.</summary>
    public string Path { get; }

    /// <summary>Writes <paramref name="contents"/> to a fresh temp file.</summary>
    public static TempConfig Write(string contents)
    {
        var path = System.IO.Path.Combine(
            System.IO.Path.GetTempPath(),
            $"procul-config-{Guid.NewGuid():N}.jsonc");
        File.WriteAllText(path, contents);
        return new TempConfig(path);
    }

    public void Dispose()
    {
        try
        {
            File.Delete(Path);
        }
        catch (IOException)
        {
            // Best-effort cleanup.
        }
    }
}
