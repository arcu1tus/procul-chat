using System.ComponentModel;
using Lokad.Lython;
using Microsoft.Extensions.AI;

namespace Procul.Api.Chat.Tools;

/// <summary>
/// The <c>run_python</c> tool: runs a short Python 3 script in a contained sandbox so the
/// model can compute reliably (math, statistics, dates) instead of doing arithmetic in its
/// head. Backed by <see cref="LythonEngine"/>; all file/network/process effects are denied by
/// <see cref="DenyAllLythonHost"/>.
/// </summary>
internal static class PythonSandbox
{
    private static readonly TimeSpan Timeout = TimeSpan.FromSeconds(5);

    /// <summary>The <c>run_python</c> tool, exposed to the model via <see cref="AgentTools.All"/>.</summary>
    public static readonly AIFunction RunPython =
        AIFunctionFactory.Create(RunPythonAsync, "run_python");

    [Description("Runs a short Python 3 script and returns its printed output. " +
                 "Contained sandbox: no file/network/system access; only a small stdlib subset.")]
    private static async Task<string> RunPythonAsync(
        [Description("The full Python source code to execute. Use print() for output.")]
        string code,
        CancellationToken ct)
    {
        var engine = new LythonEngine();
        var options = new LythonRunOptions
        {
            SourcePath = "script.py",
            MaxExecutionSteps = 5_000_000,
            MaxStandardOutputBytes = 16 * 1024,
            MaxStandardErrorBytes = 8 * 1024,
        };

        // Lython cancellation is cooperative; give the model a hard wall-clock ceiling on top
        // of the caller's token so a runaway script cannot stall the stream.
        using var timeout = CancellationTokenSource.CreateLinkedTokenSource(ct);
        timeout.CancelAfter(Timeout);

        try
        {
            var result = await engine.RunAsync(code, new DenyAllLythonHost(), options, timeout.Token);
            return result.State switch
            {
                LythonExecutionResult.SucceededState => Describe(result),
                LythonExecutionResult.CompilationFailedState => "Compilation failed:\n" +
                    string.Join('\n', result.Diagnostics
                        .Where(d => d.Severity == LythonDiagnosticSeverity.Error)
                        .Select(d => $"{d.Code}: {d.Message}")),
                LythonExecutionResult.RuntimeFailedState runtime =>
                    $"Runtime error ({runtime.Failure.ExceptionType}): {runtime.Failure.Message}\n{Trim(result.StandardOutput)}",
                _ => "(no output)",
            };
        }
        catch (OperationCanceledException) when (timeout.IsCancellationRequested && !ct.IsCancellationRequested)
        {
            return $"Execution timed out after {Timeout.TotalSeconds:0} seconds.";
        }
    }

    /// <summary>Returns captured output, or a placeholder when the script printed nothing.</summary>
    private static string Describe(LythonExecutionResult result)
        => Trim(result.StandardOutput + result.StandardError);

    private static string Trim(string text)
    {
        var trimmed = text.Trim();
        return trimmed.Length == 0 ? "(no output)" : trimmed;
    }
}

/// <summary>
/// An <see cref="ILythonHost"/> that grants no ambient authority: the clock is real, but every
/// file, directory and path operation throws <see cref="LythonHostCapabilityUnavailableException"/>.
/// This makes <c>open</c>, <c>os</c>, <c>pathlib</c> and <c>subprocess</c> fail explicitly, so a
/// script can only compute and print. Optional capabilities (std streams, binary I/O,
/// subprocess, timing) keep their default "unavailable" implementations.
/// </summary>
internal sealed class DenyAllLythonHost : ILythonHost
{
    public string Cwd => "/";

    public DateTimeOffset LocalNow => DateTimeOffset.UtcNow;

    public DateTimeOffset UtcNow => DateTimeOffset.UtcNow;

    public ValueTask<ReadOnlyMemory<byte>> ReadTextUtf8Async(string path, CancellationToken cancellationToken)
        => throw Denied("file access");

    public ValueTask WriteTextUtf8Async(string path, ReadOnlyMemory<byte> utf8, CancellationToken cancellationToken)
        => throw Denied("file access");

    public ValueTask AppendTextUtf8Async(string path, ReadOnlyMemory<byte> utf8, CancellationToken cancellationToken)
        => throw Denied("file access");

    public ValueTask<bool> ExistsAsync(string path, CancellationToken cancellationToken)
        => throw Denied("file access");

    public ValueTask<IReadOnlyList<string>> ListDirAsync(string path, CancellationToken cancellationToken)
        => throw Denied("directory access");

    public ValueTask MkDirAsync(string path, CancellationToken cancellationToken)
        => throw Denied("file access");

    public ValueTask RemoveAsync(string path, CancellationToken cancellationToken)
        => throw Denied("file access");

    public ValueTask CopyAsync(string source, string destination, CancellationToken cancellationToken)
        => throw Denied("file access");

    public ValueTask MoveAsync(string source, string destination, CancellationToken cancellationToken)
        => throw Denied("file access");

    public ValueTask<LythonPathStat> StatAsync(string path, CancellationToken cancellationToken)
        => throw Denied("file access");

    private static LythonHostCapabilityUnavailableException Denied(string capability)
        => new(capability);
}
