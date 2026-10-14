using System.Text;

namespace Procul.Api.Chat.V1;

/// <summary>Captures displayable turn activity separately from assistant answer text.</summary>
internal sealed class TurnResponseCapture
{
    public StringBuilder Reasoning { get; } = new();
    public List<ConversationToolCall> ToolCalls { get; } = [];
    public bool HasContent => Reasoning.Length > 0 || ToolCalls.Count > 0;

    public void AddCall(string id, string name, string? arguments)
    {
        if (ToolCalls.Any(t => t.CallId == id)) return;
        ToolCalls.Add(new() { Sequence = ToolCalls.Count, CallId = id, Name = name, Arguments = arguments });
    }

    public void SetResult(string id, string? result, string? error)
    {
        var call = ToolCalls.FirstOrDefault(t => t.CallId == id);
        if (call is null) return;
        call.Result = result;
        call.Error = error;
        call.Status = error is null ? "completed" : "failed";
    }

    public void Finish(string status)
    {
        foreach (var call in ToolCalls.Where(t => t.Status == "pending"))
        {
            call.Status = status == "failed" ? "failed" : "interrupted";
        }
    }
}
