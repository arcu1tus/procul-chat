using System.Text;
using Microsoft.Extensions.AI;
using Procul.Api.Chat;
using Procul.Api.Chat.V1;

namespace Procul.Api.Tests.Chat;

/// <summary>
/// Drives the SSE reply seam (<see cref="ChatStreamServiceV1.StreamTokens"/>) with synthetic
/// <see cref="ChatResponseUpdate"/>s. This is the same shape the OpenAI adapter yields — text
/// chunks, tool call/result content, and <see cref="UsageContent"/> (once per underlying model
/// call, which the tool-invocation loop can make several of).
/// </summary>
public class UsageStreamingTests
{
    private static async IAsyncEnumerable<ChatResponseUpdate> Updates(params ChatResponseUpdate[] updates)
    {
        foreach (var update in updates)
        {
            yield return update;
        }

        await Task.CompletedTask;
    }

    private static ChatResponseUpdate Text(string text) =>
        new(ChatRole.Assistant, text);

    private static ChatResponseUpdate Usage(long input, long output, long cached, long? total = null) =>
        new(ChatRole.Assistant, new List<AIContent>
        {
            new UsageContent(new UsageDetails
            {
                InputTokenCount = input,
                OutputTokenCount = output,
                CachedInputTokenCount = cached,
                TotalTokenCount = total,
            }),
        });

    private static async Task<(List<ChatStreamEventV1> Events, string Reply)> Run(
        IAsyncEnumerable<ChatResponseUpdate> updates,
        TurnUsageTotals usage)
    {
        var events = new List<ChatStreamEventV1>();
        var reply = new StringBuilder();

        await foreach (var evt in ChatStreamServiceV1.StreamTokens(updates, reply, usage, CancellationToken.None))
        {
            events.Add(evt);
        }

        return (events, reply.ToString());
    }

    [Fact]
    public async Task Emits_a_single_usage_event_with_the_counts_summed_across_calls()
    {
        var usage = new TurnUsageTotals();
        var updates = Updates(
            new ChatResponseUpdate(ChatRole.Assistant, new List<AIContent>
            {
                new FunctionCallContent("call-1", "get_current_time", new Dictionary<string, object?>
                {
                    ["utcOffsetMinutes"] = 120,
                }),
            }),
            new ChatResponseUpdate(ChatRole.Assistant, new List<AIContent>
            {
                new FunctionResultContent("call-1", "2026-10-11T15:38:44+02:00"),
            }),
            Usage(input: 10, output: 5, cached: 2),
            Text("It is "),
            Text("15:38"),
            Usage(input: 1, output: 1, cached: 0));

        var (events, reply) = await Run(updates, usage);

        // Tokens still flow, tool activity is forwarded, and there is exactly one usage event.
        Assert.Contains(events, e => e is ChatStreamEventV1.ToolCall);
        Assert.Contains(events, e => e is ChatStreamEventV1.ToolResult);
        Assert.Equal(2, events.OfType<ChatStreamEventV1.Token>().Count());
        Assert.Equal("It is 15:38", reply);

        var usageEvent = Assert.Single(events.OfType<ChatStreamEventV1.Usage>());
        Assert.Equal(11, usageEvent.Value.InputTokens);
        Assert.Equal(6, usageEvent.Value.OutputTokens);
        Assert.Equal(2, usageEvent.Value.CachedInputTokens);
        Assert.Equal(17, usageEvent.Value.TotalTokens);
        Assert.Equal("usage", usageEvent.Value.Type);

        // The usage event trails the tokens, just before `done`.
        Assert.IsType<ChatStreamEventV1.Usage>(events[^1]);

        // And the accumulator carries the same totals for persistence.
        Assert.True(usage.HasUsage);
        Assert.Equal(11, usage.InputTokens);
        Assert.Equal(17, usage.TotalTokens);
        Assert.Equal(2, usage.UsageCount);
    }

    [Fact]
    public async Task Emits_no_usage_event_when_the_model_reports_none()
    {
        var usage = new TurnUsageTotals();

        var (events, reply) = await Run(Updates(Text("Hello"), Text(" world")), usage);

        Assert.Equal("Hello world", reply);
        Assert.Empty(events.OfType<ChatStreamEventV1.Usage>());
        Assert.False(usage.HasUsage);
    }

    [Fact]
    public async Task Falls_back_to_input_plus_output_when_total_is_omitted()
    {
        var usage = new TurnUsageTotals();

        var (events, _) = await Run(Updates(Usage(input: 7, output: 3, cached: 0, total: null)), usage);

        var usageEvent = Assert.Single(events.OfType<ChatStreamEventV1.Usage>());
        Assert.Equal(10, usageEvent.Value.TotalTokens);
    }
}
