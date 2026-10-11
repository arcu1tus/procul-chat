namespace Procul.Api.Chat;

/// <summary>
/// The model the chat client is configured with, captured at startup. Persisted alongside
/// token usage so each row records which model produced it (and the aggregate can break
/// usage down per model).
/// </summary>
public sealed record ChatModelOptions(string Model);
