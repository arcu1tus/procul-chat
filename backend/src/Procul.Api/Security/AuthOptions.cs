using Procul.Api.Configuration;

namespace Procul.Api.Security;

/// <summary>
/// The API's shared-password authentication settings. The password is a secret and stays an
/// environment variable; the session lifetime comes from <c>server.sessionLifetime</c> in
/// <c>config.jsonc</c>.
/// </summary>
public sealed class AuthOptions
{
    /// <summary>Configuration key holding the shared password. Required.</summary>
    public const string PasswordSetting = "PROCUL_API_PASSWORD";

    /// <summary>The config path holding the session-token lifetime.</summary>
    public const string SessionLifetimeConfigPath = "server.sessionLifetime";

    /// <summary>The lifetime used when <c>server.sessionLifetime</c> is unset.</summary>
    public static readonly TimeSpan DefaultSessionLifetime = TimeSpan.FromDays(30);

    /// <summary>The shared password every session token is derived from.</summary>
    public required string Password { get; init; }

    /// <summary>How long an issued session token stays valid.</summary>
    public required TimeSpan SessionLifetime { get; init; }

    /// <summary>
    /// Builds the settings from the validated config plus the password environment variable. A
    /// missing password or a malformed lifetime is fatal so a misconfigured deployment fails fast
    /// instead of silently exposing the API.
    /// </summary>
    /// <exception cref="InvalidOperationException">
    /// Thrown when <see cref="PasswordSetting"/> is unset/empty or <c>server.sessionLifetime</c>
    /// is not a valid duration.
    /// </exception>
    public static AuthOptions FromConfig(ProculConfig config, string? password)
    {
        if (string.IsNullOrEmpty(password))
        {
            throw new InvalidOperationException(
                $"The {PasswordSetting} environment variable is not set. Set it to a strong " +
                "shared password; it is required and protects the entire API.");
        }

        return new AuthOptions
        {
            Password = password,
            SessionLifetime = DurationParser.Parse(
                config.Server.SessionLifetime, DefaultSessionLifetime, SessionLifetimeConfigPath),
        };
    }
}
