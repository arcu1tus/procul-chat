using Procul.Api.Chat;
using Procul.Api.Usage;

namespace Procul.Api.Tests.Usage;

/// <summary>
/// Pure aggregation logic for the usage dashboard: UTC day bucketing, zero-fill, window
/// boundaries, totals, and the per-model breakdown. No database involved.
/// </summary>
public class UsageAggregatorTests
{
    private static readonly DateOnly To = new(2026, 10, 11);
    private static readonly DateOnly From = new(2026, 10, 5);

    private static TurnUsage Row(
        string day,
        long input,
        long output,
        long cached,
        string model = "test/model")
    {
        var createdAt = DateTimeOffset.Parse($"{day}T12:00:00Z");
        return new TurnUsage
        {
            ConversationId = Guid.CreateVersion7(),
            Model = model,
            Kind = TurnKind.Chat,
            InputTokens = input,
            OutputTokens = output,
            CachedInputTokens = cached,
            TotalTokens = input + output,
            CreatedAt = createdAt,
        };
    }

    private static List<TurnUsage> Sample() =>
    [
        Row("2026-10-11", 10, 5, 2, "a"),
        Row("2026-10-11", 1, 1, 0, "b"),
        Row("2026-10-10", 3, 4, 1, "a"),
        // Just outside the window on either side — must be ignored by PerDay.
        Row("2026-10-04", 100, 0, 0, "a"),
        Row("2026-10-12", 200, 0, 0, "a"),
    ];

    [Fact]
    public void Lifetime_sums_every_row_and_counts_model_calls()
    {
        var totals = UsageAggregator.Lifetime(Sample());

        Assert.Equal(314, totals.InputTokens);
        Assert.Equal(10, totals.OutputTokens);
        Assert.Equal(3, totals.CachedInputTokens);
        // 15 + 2 + 7 + 100 + 200
        Assert.Equal(324, totals.TotalTokens);
        Assert.Equal(5, totals.Turns);
    }

    [Fact]
    public void Lifetime_of_nothing_is_all_zero()
    {
        var totals = UsageAggregator.Lifetime([]);

        Assert.Equal(0, totals.InputTokens);
        Assert.Equal(0, totals.OutputTokens);
        Assert.Equal(0, totals.CachedInputTokens);
        Assert.Equal(0, totals.TotalTokens);
        Assert.Equal(0, totals.Turns);
    }

    [Fact]
    public void PerDay_zero_fills_the_whole_window_oldest_first()
    {
        var days = UsageAggregator.PerDay(Sample(), From, To);

        Assert.Equal(7, days.Count);
        Assert.Equal("2026-10-05", days[0].Date);
        Assert.Equal("2026-10-11", days[6].Date);

        // Days with no rows are present but zero.
        for (var i = 0; i < 5; i++)
        {
            Assert.Equal(0, days[i].TotalTokens);
            Assert.Equal(0, days[i].Turns);
        }
    }

    [Fact]
    public void PerDay_buckets_by_utc_day_and_sums_each_day()
    {
        var days = UsageAggregator.PerDay(Sample(), From, To);

        var oct10 = days.Single(d => d.Date == "2026-10-10");
        Assert.Equal(3, oct10.InputTokens);
        Assert.Equal(4, oct10.OutputTokens);
        Assert.Equal(1, oct10.CachedInputTokens);
        Assert.Equal(7, oct10.TotalTokens);
        Assert.Equal(1, oct10.Turns);

        var oct11 = days.Single(d => d.Date == "2026-10-11");
        Assert.Equal(11, oct11.InputTokens);
        Assert.Equal(6, oct11.OutputTokens);
        Assert.Equal(2, oct11.CachedInputTokens);
        Assert.Equal(17, oct11.TotalTokens);
        Assert.Equal(2, oct11.Turns);
    }

    [Fact]
    public void PerDay_ignores_rows_just_outside_the_window()
    {
        var days = UsageAggregator.PerDay(Sample(), From, To);

        var summed = days.Sum(d => d.TotalTokens);
        // Only the three in-window rows (15 + 2 + 7); the 100 and 200 are excluded.
        Assert.Equal(24, summed);
    }

    [Fact]
    public void InWindow_is_inclusive_on_both_ends()
    {
        Assert.True(UsageAggregator.InWindow(Row("2026-10-05", 0, 0, 0), From, To));
        Assert.True(UsageAggregator.InWindow(Row("2026-10-11", 0, 0, 0), From, To));
        Assert.False(UsageAggregator.InWindow(Row("2026-10-04", 0, 0, 0), From, To));
        Assert.False(UsageAggregator.InWindow(Row("2026-10-12", 0, 0, 0), From, To));
    }

    [Fact]
    public void PerDay_buckets_by_utc_not_local_time()
    {
        // 2026-10-10T23:30:00+02:00 is 2026-10-10T21:30:00Z — still the 10th in UTC.
        var row = new TurnUsage
        {
            Model = "a",
            CreatedAt = DateTimeOffset.Parse("2026-10-10T23:30:00+02:00"),
            InputTokens = 5,
            TotalTokens = 5,
        };

        var days = UsageAggregator.PerDay([row], From, To);

        Assert.Equal(5, days.Single(d => d.Date == "2026-10-10").InputTokens);
        Assert.Equal(0, days.Single(d => d.Date == "2026-10-11").InputTokens);
    }

    [Fact]
    public void PerModel_sums_per_model_ranked_by_total()
    {
        var models = UsageAggregator.PerModel(Sample().Where(r => UsageAggregator.InWindow(r, From, To)));

        Assert.Equal(2, models.Count);
        Assert.Equal("a", models[0].Model);
        Assert.Equal(13, models[0].InputTokens);
        Assert.Equal(9, models[0].OutputTokens);
        Assert.Equal(3, models[0].CachedInputTokens);
        Assert.Equal(22, models[0].TotalTokens);
        Assert.Equal(2, models[0].Turns);

        Assert.Equal("b", models[1].Model);
        Assert.Equal(2, models[1].TotalTokens);
        Assert.Equal(1, models[1].Turns);
    }

    [Fact]
    public void PerModel_uses_a_placeholder_for_a_blank_model()
    {
        var rows = new[]
        {
            Row("2026-10-11", 1, 1, 0, ""),
        };

        var models = UsageAggregator.PerModel(rows);

        Assert.Equal("(unknown)", models.Single().Model);
    }
}
