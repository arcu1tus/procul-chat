namespace Procul.Api.Usage.V1;

// Versioned response DTOs for the v1 usage endpoints. Serialized as camelCase
// (JsonSerializerDefaults.Web). Tokens only — there is no dollar-cost estimate.

/// <summary>Token sums plus the number of model calls they cover.</summary>
public sealed record UsageTotalsV1(
    long InputTokens,
    long OutputTokens,
    long CachedInputTokens,
    long TotalTokens,
    long Turns
);

/// <summary>One UTC day's sums. <c>Date</c> is an ISO <c>yyyy-MM-dd</c> string.</summary>
public sealed record UsageDayV1(
    string Date,
    long InputTokens,
    long OutputTokens,
    long CachedInputTokens,
    long TotalTokens,
    long Turns
);

/// <summary>One model's sums over the requested window.</summary>
public sealed record UsageModelV1(
    string Model,
    long InputTokens,
    long OutputTokens,
    long CachedInputTokens,
    long TotalTokens,
    long Turns
);

/// <summary>Body of <c>GET /v{version}/usage</c>.</summary>
public sealed record GetUsageResponseV1(
    UsageTotalsV1 Lifetime,
    List<UsageDayV1> Days,
    List<UsageModelV1> Models
);
