using System.Globalization;
using Procul.Api.Chat;
using Procul.Api.Usage.V1;

namespace Procul.Api.Usage;

/// <summary>
/// Pure, provider-agnostic token-usage bucketing. Kept in C# (rather than a provider-specific
/// <c>GROUP BY</c>) so it can be unit-tested without Postgres and stays portable. All bucketing
/// is by <b>UTC</b> calendar day.
/// </summary>
internal static class UsageAggregator
{
    /// <summary>Whether a row falls on one of the days in the inclusive UTC window.</summary>
    public static bool InWindow(TurnUsage row, DateOnly fromInclusive, DateOnly toInclusive)
    {
        var day = Day(row);
        return day >= fromInclusive && day <= toInclusive;
    }

    /// <summary>All-time sums: tokens plus the number of model calls (rows).</summary>
    public static UsageTotalsV1 Lifetime(IEnumerable<TurnUsage> rows)
    {
        long input = 0, output = 0, cached = 0, total = 0, turns = 0;
        foreach (var row in rows)
        {
            input += row.InputTokens;
            output += row.OutputTokens;
            cached += row.CachedInputTokens;
            total += row.TotalTokens;
            turns++;
        }

        return new UsageTotalsV1(input, output, cached, total, turns);
    }

    /// <summary>
    /// Per-UTC-day sums over the inclusive window, oldest first. Every day in the window is
    /// present (missing days are zero-filled); rows outside the window are ignored.
    /// </summary>
    public static List<UsageDayV1> PerDay(
        IEnumerable<TurnUsage> rows,
        DateOnly fromInclusive,
        DateOnly toInclusive)
    {
        var buckets = new Dictionary<DateOnly, Accumulator>();
        for (var day = fromInclusive; day <= toInclusive; day = day.AddDays(1))
        {
            buckets[day] = default;
        }

        foreach (var row in rows)
        {
            var day = Day(row);
            if (day < fromInclusive || day > toInclusive || !buckets.ContainsKey(day))
            {
                continue;
            }

            var bucket = buckets[day];
            bucket.Add(row);
            buckets[day] = bucket;
        }

        return buckets
            .OrderBy(pair => pair.Key)
            .Select(pair => new UsageDayV1(
                pair.Key.ToString("yyyy-MM-dd", CultureInfo.InvariantCulture),
                pair.Value.Input,
                pair.Value.Output,
                pair.Value.Cached,
                pair.Value.Total,
                pair.Value.Turns))
            .ToList();
    }

    /// <summary>Per-model sums over the given rows, highest total first (ties by model name).</summary>
    public static List<UsageModelV1> PerModel(IEnumerable<TurnUsage> rows)
    {
        var buckets = new Dictionary<string, Accumulator>(StringComparer.Ordinal);
        foreach (var row in rows)
        {
            var model = string.IsNullOrEmpty(row.Model) ? "(unknown)" : row.Model;
            if (!buckets.TryGetValue(model, out var bucket))
            {
                bucket = default;
            }

            bucket.Add(row);
            buckets[model] = bucket;
        }

        return buckets
            .OrderByDescending(pair => pair.Value.Total)
            .ThenBy(pair => pair.Key, StringComparer.Ordinal)
            .Select(pair => new UsageModelV1(
                pair.Key,
                pair.Value.Input,
                pair.Value.Output,
                pair.Value.Cached,
                pair.Value.Total,
                pair.Value.Turns))
            .ToList();
    }

    private static DateOnly Day(TurnUsage row) => DateOnly.FromDateTime(row.CreatedAt.UtcDateTime);

    /// <summary>A mutable token sum for one bucket.</summary>
    private struct Accumulator
    {
        public long Input;
        public long Output;
        public long Cached;
        public long Total;
        public long Turns;

        public void Add(TurnUsage row)
        {
            Input += row.InputTokens;
            Output += row.OutputTokens;
            Cached += row.CachedInputTokens;
            Total += row.TotalTokens;
            Turns++;
        }
    }
}
