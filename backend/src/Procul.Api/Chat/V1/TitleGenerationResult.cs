namespace Procul.Api.Chat.V1;

/// <summary>
/// The outcome of the concurrent title model call: the sanitized title (null when the model
/// produced nothing usable) plus the token usage that call reported (empty when none).
/// </summary>
internal sealed record TitleGenerationResult(string? Title, TurnUsageTotals Usage);
