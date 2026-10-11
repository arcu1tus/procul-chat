using Microsoft.Extensions.AI;

namespace Procul.Api.Chat.Tools;

/// <summary>
/// Registry of the tools exposed to the chat model, plus the system prompt that tells the
/// model what they are for. The tools are passed via <see cref="ChatOptions.Tools"/> on each
/// turn; execution is automatic because the client is wrapped with
/// <c>UseFunctionInvocation()</c> (see <c>Program.cs</c>).
/// </summary>
internal static class AgentTools
{
    /// <summary>Every tool made available to the model.</summary>
    public static IReadOnlyList<AITool> All { get; } =
        [TimeTool.CurrentTime, PythonSandbox.RunPython];

    /// <summary>
    /// Prepended to the conversation as a <see cref="ChatRole.System"/> message. Kept short:
    /// it only has to explain when each tool is useful and the sandbox's boundaries.
    /// </summary>
    public const string SystemPrompt = """
        You are a helpful assistant. Use tools when they help:
        - get_current_time: current date/time.
        - run_python: run short Python 3 to compute things reliably (math, stats, dates).
          It is a sandbox: no file, network, or system access, and only a small
          standard-library subset (math, statistics, decimal, random, itertools,
          functools, json, re, collections, datetime, time, ...). Print your results.
        """;
}
