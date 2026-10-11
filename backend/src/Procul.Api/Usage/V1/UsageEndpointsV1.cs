using Microsoft.AspNetCore.Http.HttpResults;
using Microsoft.EntityFrameworkCore;
using Procul.Api.Infrastructure;

namespace Procul.Api.Usage.V1;

internal static class UsageEndpointsV1
{
    /// <summary>Largest window <c>days</c> may ask for (a full year plus one).</summary>
    private const int MaxDays = 366;

    /// <summary>Window used when the client does not pass <c>days</c>.</summary>
    private const int DefaultDays = 30;

    public static RouteGroupBuilder MapUsageV1(this RouteGroupBuilder group)
    {
        group.MapGet("/", GetUsage);
        group.MapGet("/conversations/{conversationId:guid}", GetConversationUsage);
        return group;
    }

    /// <summary>
    /// All-time totals plus a per-UTC-day and per-model breakdown of the requested window.
    /// <c>lifetime</c> always ignores the window; <c>days</c> and <c>models</c> honor it.
    /// </summary>
    private static async Task<Results<Ok<GetUsageResponseV1>, ProblemHttpResult>> GetUsage(
        ProculDbContext db,
        int days = DefaultDays,
        CancellationToken ct = default
    )
    {
        if (days < 1 || days > MaxDays)
        {
            return TypedResults.Problem(
                title: "Invalid window",
                detail: $"The 'days' query parameter must be between 1 and {MaxDays}.",
                statusCode: StatusCodes.Status400BadRequest);
        }

        var today = DateOnly.FromDateTime(DateTime.UtcNow);
        var from = today.AddDays(-(days - 1));

        var rows = await db.TurnUsages.AsNoTracking().ToListAsync(ct);

        return TypedResults.Ok(new GetUsageResponseV1(
            UsageAggregator.Lifetime(rows),
            UsageAggregator.PerDay(rows, from, today),
            UsageAggregator.PerModel(rows.Where(row => UsageAggregator.InWindow(row, from, today)))));
    }

    /// <summary>All-time totals for one conversation. Drives the in-chat app-bar counter.</summary>
    private static async Task<Ok<UsageTotalsV1>> GetConversationUsage(
        Guid conversationId,
        ProculDbContext db,
        CancellationToken ct
    )
    {
        var rows = await db.TurnUsages
            .AsNoTracking()
            .Where(row => row.ConversationId == conversationId)
            .ToListAsync(ct);

        return TypedResults.Ok(UsageAggregator.Lifetime(rows));
    }
}
