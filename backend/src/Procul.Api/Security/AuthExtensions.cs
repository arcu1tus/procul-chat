using Microsoft.AspNetCore.Authentication.JwtBearer;
using Microsoft.IdentityModel.Tokens;
using Procul.Api.Configuration;

namespace Procul.Api.Security;

/// <summary>
/// Wires the shared-password session authentication: the password verifier, the token issuer,
/// and JWT bearer validation.
/// </summary>
public static class AuthExtensions
{
    /// <summary>
    /// Registers the authentication services and the session-token machinery.
    /// </summary>
    /// <exception cref="InvalidOperationException">
    /// Thrown when <see cref="AuthOptions.PasswordSetting"/> is missing or
    /// <c>server.sessionLifetime</c> is malformed, so a misconfigured deployment fails fast.
    /// </exception>
    public static IServiceCollection AddProculAuth(
        this IServiceCollection services,
        IConfiguration configuration,
        ProculConfig config)
    {
        var options = AuthOptions.FromConfig(config, configuration[AuthOptions.PasswordSetting]);

        services.AddSingleton(options);
        services.AddSingleton(new PasswordVerifier(options.Password));
        services.AddSingleton(new SessionTokenService(options));

        services
            .AddAuthentication(JwtBearerDefaults.AuthenticationScheme)
            .AddJwtBearer(jwt =>
            {
                jwt.TokenValidationParameters = new TokenValidationParameters
                {
                    // The tokens are self-issued with a key derived from the password, so there is
                    // no external issuer or audience to validate.
                    ValidateIssuer = false,
                    ValidateAudience = false,
                    ValidateIssuerSigningKey = true,
                    IssuerSigningKey = SessionTokenService.CreateSigningKey(options.Password),
                    ValidateLifetime = true,
                    // Honor the token's `exp` exactly instead of the default five-minute grace.
                    ClockSkew = TimeSpan.Zero,
                    ValidAlgorithms = [SecurityAlgorithms.HmacSha256],
                };
            });

        services.AddAuthorization();
        return services;
    }

    /// <summary>
    /// Adds authentication/authorization to the pipeline. Must run after CORS so preflight
    /// (<c>OPTIONS</c>) requests stay unauthenticated, and before the endpoints.
    /// </summary>
    public static IApplicationBuilder UseProculAuth(this WebApplication app)
    {
        app.UseAuthentication();
        app.UseAuthorization();
        return app;
    }
}
