using System.Security.Claims;
using System.Security.Cryptography;
using System.Text;
using Microsoft.IdentityModel.JsonWebTokens;
using Microsoft.IdentityModel.Tokens;

namespace Procul.Api.Security;

/// <summary>
/// Issues the short-lived session tokens the client exchanges its password for.
///
/// <para>
/// Tokens are HS256 JWTs whose signing key is derived from the configured password plus a fixed
/// application context string. Deriving the key this way means <b>changing the password
/// invalidates every previously issued token</b> without any server-side token store.
/// </para>
/// </summary>
public sealed class SessionTokenService
{
    private const string Subject = "procul";

    /// <summary>
    /// Mixed into the signing key so the same password produces a different key in a different
    /// application context.
    /// </summary>
    private const string KeyContext = "procul-api/session/v1";

    private readonly SigningCredentials _credentials;
    private readonly TimeSpan _lifetime;

    public SessionTokenService(AuthOptions options)
    {
        _credentials = new SigningCredentials(CreateSigningKey(options.Password), SecurityAlgorithms.HmacSha256);
        _lifetime = options.SessionLifetime;
    }

    /// <summary>
    /// Builds the HS256 signing key for <paramref name="password"/>. Shared with the JWT bearer
    /// validation setup so issuing and validating always agree.
    /// </summary>
    public static SymmetricSecurityKey CreateSigningKey(string password)
    {
        var key = SHA256.HashData(Encoding.UTF8.GetBytes(password + KeyContext));
        return new SymmetricSecurityKey(key);
    }

    /// <summary>
    /// Issues a new token for the configured lifetime. The returned <c>expiresAt</c> matches the
    /// token's <c>exp</c> claim.
    /// </summary>
    public (string Token, DateTimeOffset ExpiresAt) IssueToken()
    {
        var issuedAt = DateTimeOffset.UtcNow;
        var expiresAt = issuedAt.Add(_lifetime);

        var token = new JsonWebTokenHandler().CreateToken(new SecurityTokenDescriptor
        {
            Subject = new ClaimsIdentity([new Claim(JwtRegisteredClaimNames.Sub, Subject)]),
            IssuedAt = issuedAt.UtcDateTime,
            Expires = expiresAt.UtcDateTime,
            SigningCredentials = _credentials,
        });

        return (token, expiresAt);
    }
}
