using System.Text.Json;
using Microsoft.Extensions.AI;
using Procul.Api.Chat.Tools;

namespace Procul.Api.Tests.Chat.Tools;

/// <summary>
/// The tools are invoked directly through their <see cref="AIFunction"/> wrappers, the same way
/// <c>UseFunctionInvocation()</c> invokes them at runtime. Results come back boxed as
/// <see cref="JsonElement"/> (the same behavior the streaming service unwraps in production).
/// </summary>
public class ToolTests
{
    [Fact]
    public async Task GetCurrentTime_returns_iso8601_at_the_requested_offset()
    {
        var result = await TimeTool.CurrentTime.InvokeAsync(
            new AIFunctionArguments { ["utcOffsetMinutes"] = 120 });

        var parsed = DateTimeOffset.Parse(AsText(result));
        Assert.Equal(TimeSpan.FromHours(2), parsed.Offset);
    }

    [Fact]
    public async Task GetCurrentTime_defaults_to_utc()
    {
        var result = await TimeTool.CurrentTime.InvokeAsync();

        var parsed = DateTimeOffset.Parse(AsText(result));
        Assert.Equal(TimeSpan.Zero, parsed.Offset);
    }

    [Fact]
    public async Task RunPython_returns_printed_output()
    {
        var result = await PythonSandbox.RunPython.InvokeAsync(
            new AIFunctionArguments { ["code"] = "print(1 + 1)" });

        Assert.Equal("2", AsText(result));
    }

    [Fact]
    public async Task RunPython_reports_compilation_errors()
    {
        var result = await PythonSandbox.RunPython.InvokeAsync(
            new AIFunctionArguments { ["code"] = "def (" });

        Assert.Contains("Compilation failed", AsText(result));
    }

    [Fact]
    public async Task RunPython_denies_file_access()
    {
        var result = await PythonSandbox.RunPython.InvokeAsync(
            new AIFunctionArguments { ["code"] = "print(open('/etc/passwd').read())" });

        Assert.Contains("Runtime error", AsText(result));
    }

    private static string AsText(object? result) => result switch
    {
        JsonElement { ValueKind: JsonValueKind.String } element => element.GetString() ?? string.Empty,
        JsonElement element => element.GetRawText(),
        string text => text,
        null => string.Empty,
        _ => result.ToString() ?? string.Empty,
    };
}
