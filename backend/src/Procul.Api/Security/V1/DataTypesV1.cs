namespace Procul.Api.Security.V1;

// Versioned request/response DTOs for the v1 auth endpoints. Serialized as camelCase
// (JsonSerializerDefaults.Web).

/// <summary>Body of <c>POST /v{version}/auth/session</c>.</summary>
public sealed record CreateSessionRequestV1(string? Password);

/// <summary>
/// The session token issued by <c>POST /v{version}/auth/session</c>. The client sends the
/// <see cref="Token"/> as <c>Authorization: Bearer …</c> on every subsequent request.
/// </summary>
public sealed record CreateSessionResponseV1(string Token, DateTimeOffset ExpiresAt);
