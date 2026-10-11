using Microsoft.Extensions.AI;

namespace Procul.Api.Chat;

/// <summary>
/// Sums token counts across every <see cref="UsageContent"/> seen on a turn. A turn can make
/// several underlying model calls (the reply plus each step of the tool-invocation loop, and
/// separately the title call), and providers may report usage more than once; the totals the
/// client and the database see are the sum of all of them.
/// </summary>
internal sealed class TurnUsageTotals
{
    public long InputTokens { get; private set; }
    public long OutputTokens { get; private set; }
    public long CachedInputTokens { get; private set; }
    public long TotalTokens { get; private set; }

    /// <summary>How many usage payloads have been folded in.</summary>
    public int UsageCount { get; private set; }

    /// <summary>Whether any usage was reported at all.</summary>
    public bool HasUsage => UsageCount > 0;

    /// <summary>
    /// Folds one usage payload into the running totals. Missing fields count as zero; when the
    /// provider omits <see cref="UsageDetails.TotalTokenCount"/> the input + output sum stands
    /// in for it.
    /// </summary>
    public void Add(UsageDetails? usage)
    {
        if (usage is null)
        {
            return;
        }

        UsageCount++;

        var input = usage.InputTokenCount ?? 0;
        var output = usage.OutputTokenCount ?? 0;

        InputTokens += input;
        OutputTokens += output;
        CachedInputTokens += usage.CachedInputTokenCount ?? 0;
        TotalTokens += usage.TotalTokenCount ?? input + output;
    }

    /// <summary>Materializes the totals as a persistable row.</summary>
    public TurnUsage ToTurnUsage(Guid conversationId, string model, TurnKind kind) => new()
    {
        ConversationId = conversationId,
        Model = model,
        Kind = kind,
        InputTokens = InputTokens,
        OutputTokens = OutputTokens,
        CachedInputTokens = CachedInputTokens,
        TotalTokens = TotalTokens,
    };
}
