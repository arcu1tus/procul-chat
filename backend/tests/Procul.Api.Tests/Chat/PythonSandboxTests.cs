using System.Text.Json;
using Microsoft.Extensions.AI;
using Procul.Api.Chat.Tools;

namespace Procul.Api.Tests.Chat;

/// <summary>
/// Proves the <c>run_python</c> sandbox is contained: file/process/network operations fail
/// explicitly, and the step/output caps hold. The host grants no ambient authority, so even the
/// importable system modules cannot reach the outside world.
/// </summary>
public class PythonSandboxTests
{
    private static async Task<string> RunAsync(string code)
    {
        var result = await PythonSandbox.RunPython.InvokeAsync(
            new AIFunctionArguments { ["code"] = code });
        return AsText(result);
    }

    private static string AsText(object? result) => result switch
    {
        JsonElement { ValueKind: JsonValueKind.String } element => element.GetString() ?? string.Empty,
        JsonElement element => element.GetRawText(),
        string text => text,
        null => string.Empty,
        _ => result.ToString() ?? string.Empty,
    };

    [Theory]
    [InlineData("print(open('/etc/passwd').read())")]
    [InlineData("import pathlib\nprint(pathlib.Path('/etc/passwd').read_text())")]
    [InlineData("import socket\nsocket.socket()")]
    [InlineData("import subprocess\nsubprocess.run(['ls'])")]
    [InlineData("import glob\nprint(glob.glob('/etc/*'))")]
    public async Task Dangerous_operations_fail_explicitly(string code)
    {
        var result = await RunAsync(code);

        // No real host content leaks (an actual /etc/passwd read would contain "root:").
        Assert.DoesNotContain("root:", result);
        Assert.True(
            result.Contains("error", StringComparison.OrdinalIgnoreCase)
                || result.Contains("failed", StringComparison.OrdinalIgnoreCase)
                || result.Contains("not available", StringComparison.OrdinalIgnoreCase),
            $"Expected a sandbox failure, got: {result}");
    }

    [Fact]
    public async Task The_environment_is_not_exposed()
    {
        var result = await RunAsync("import os\nprint(list(os.environ))");

        // The sandbox passes an empty environment, so no host secrets (PATH, tokens, ...) leak.
        Assert.Equal("[]", result.Trim());
    }

    [Fact]
    public async Task A_runaway_loop_is_stopped_by_a_limit()
    {
        var result = await RunAsync("while True:\n    pass");

        // A runaway loop is contained by whichever guard fires first: the execution-step
        // budget (5M steps) or the 5s wall-clock deadline. Which one wins is timing-dependent
        // — a fast machine exhausts the step budget ("maximum execution step count exceeded")
        // while a slower CI box reaches the deadline ("execution canceled") — so assert the
        // loop was stopped by a limit, not which limit. The timeout catch is also accepted in
        // case the runtime surfaces cancellation as an exception instead of a runtime failure.
        Assert.True(
            result.Contains("step", StringComparison.OrdinalIgnoreCase)
                || result.Contains("cancel", StringComparison.OrdinalIgnoreCase)
                || result.Contains("timed out", StringComparison.OrdinalIgnoreCase),
            $"Expected the runaway loop to be stopped by a limit, got: {result}");
    }

    [Fact]
    public async Task Huge_output_is_capped()
    {
        var result = await RunAsync("print('x' * 1000000)");

        Assert.Contains("output", result, StringComparison.OrdinalIgnoreCase);
    }

    [Fact]
    public async Task Ordinary_computation_still_works()
    {
        var result = await RunAsync("import math\nprint(math.factorial(5))");

        Assert.Equal("120", result);
    }
}
