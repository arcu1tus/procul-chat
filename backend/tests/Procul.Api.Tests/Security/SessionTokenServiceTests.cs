using Microsoft.IdentityModel.JsonWebTokens;
using Microsoft.IdentityModel.Tokens;
using Procul.Api.Security;

namespace Procul.Api.Tests.Security;

public class SessionTokenServiceTests
{
    private const string Password = "correct horse battery staple";

    private static AuthOptions Options(string password = Password, TimeSpan? lifetime = null) => new()
    {
        Password = password,
        SessionLifetime = lifetime ?? TimeSpan.FromHours(1),
    };

    [Fact]
    public async Task An_issued_token_round_trips_with_the_same_password()
    {
        var (token, _) = new SessionTokenService(Options()).IssueToken();

        Assert.True(await ValidateAsync(token, Password));
    }

    [Fact]
    public async Task A_token_issued_before_a_password_change_no_longer_validates()
    {
        var (token, _) = new SessionTokenService(Options(password: "old-password")).IssueToken();

        Assert.False(await ValidateAsync(token, "new-password"));
    }

    [Fact]
    public void The_token_expires_at_the_configured_lifetime()
    {
        var lifetime = TimeSpan.FromMinutes(5);
        var before = DateTimeOffset.UtcNow;

        var (token, expiresAt) = new SessionTokenService(Options(lifetime: lifetime)).IssueToken();

        var after = DateTimeOffset.UtcNow;

        Assert.InRange(expiresAt, before.Add(lifetime), after.Add(lifetime));

        var jwt = new JsonWebTokenHandler().ReadJsonWebToken(token);
        Assert.Equal("procul", jwt.Subject);

        // JWT `exp` is whole seconds, so allow up to a second of truncation.
        Assert.InRange(
            jwt.ValidTo,
            before.Add(lifetime).AddSeconds(-1).UtcDateTime,
            after.Add(lifetime).UtcDateTime);
    }

    [Fact]
    public async Task An_expired_token_does_not_validate()
    {
        // A negative lifetime produces a token that is already past its `exp`.
        var (token, _) = new SessionTokenService(Options(lifetime: TimeSpan.FromSeconds(-10))).IssueToken();

        Assert.False(await ValidateAsync(token, Password));
    }

    private static async Task<bool> ValidateAsync(string token, string password)
    {
        var result = await new JsonWebTokenHandler().ValidateTokenAsync(
            token,
            new TokenValidationParameters
            {
                ValidateIssuer = false,
                ValidateAudience = false,
                ValidateIssuerSigningKey = true,
                IssuerSigningKey = SessionTokenService.CreateSigningKey(password),
                ValidateLifetime = true,
                ClockSkew = TimeSpan.Zero,
                ValidAlgorithms = [SecurityAlgorithms.HmacSha256],
            });

        return result.IsValid;
    }
}
