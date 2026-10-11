using System.Globalization;

namespace Procul.Api.Security;

/// <summary>
/// The API's shared-password authentication settings, read once at startup from configuration
/// (environment variables, loaded from <c>.env</c> in development).
/// </summary>
public sealed class AuthOptions
{
    /// <summary>Configuration key holding the shared password. Required.</summary>
    public const string PasswordSetting = "PROCUL_API_PASSWORD";

    /// <summary>
    /// Configuration key holding the session-token lifetime. Optional; defaults to
    /// <see cref="DefaultSessionLifetime"/>.
    /// </summary>
    public const string SessionLifetimeSetting = "PROCUL_SESSION_LIFETIME";

    /// <summary>The lifetime used when <see cref="SessionLifetimeSetting"/> is unset.</summary>
    public static readonly TimeSpan DefaultSessionLifetime = TimeSpan.FromDays(30);

    /// <summary>The shared password every session token is derived from.</summary>
    public required string Password { get; init; }

    /// <summary>How long an issued session token stays valid.</summary>
    public required TimeSpan SessionLifetime { get; init; }

    /// <summary>
    /// Reads and validates the settings. A missing password or a malformed lifetime is fatal so
    /// a misconfigured deployment fails fast instead of silently exposing the API.
    /// </summary>
    /// <exception cref="InvalidOperationException">
    /// Thrown when <see cref="PasswordSetting"/> is unset/empty or <see cref="SessionLifetimeSetting"/>
    /// is not a valid duration.
    /// </exception>
    public static AuthOptions FromConfiguration(IConfiguration configuration)
    {
        var password = configuration[PasswordSetting];
        if (string.IsNullOrEmpty(password))
        {
            throw new InvalidOperationException(
                $"The {PasswordSetting} environment variable is not set. Set it to a strong " +
                "shared password; it is required and protects the entire API.");
        }

        return new AuthOptions
        {
            Password = password,
            SessionLifetime = ParseLifetime(configuration[SessionLifetimeSetting]),
        };
    }

    /// <summary>
    /// Parses a duration made of one or more <c>&lt;number&gt;&lt;unit&gt;</c> segments, where the
    /// unit is <c>d</c>, <c>h</c>, <c>m</c> or <c>s</c> (e.g. <c>30d</c>, <c>12h</c>, <c>1h30m</c>).
    /// An unset value yields <see cref="DefaultSessionLifetime"/>; anything else throws.
    /// </summary>
    internal static TimeSpan ParseLifetime(string? raw)
    {
        if (string.IsNullOrWhiteSpace(raw))
        {
            return DefaultSessionLifetime;
        }

        var value = raw.Trim();
        var total = TimeSpan.Zero;
        var index = 0;

        while (index < value.Length)
        {
            var start = index;
            while (index < value.Length && char.IsAsciiDigit(value[index]))
            {
                index++;
            }

            if (index == start || index >= value.Length)
            {
                throw MalformedLifetime(raw);
            }

            if (!long.TryParse(value.AsSpan(start, index - start), NumberStyles.None, CultureInfo.InvariantCulture, out var amount))
            {
                throw MalformedLifetime(raw);
            }

            var unit = char.ToLowerInvariant(value[index]);
            index++;

            total += unit switch
            {
                'd' => TimeSpan.FromDays(amount),
                'h' => TimeSpan.FromHours(amount),
                'm' => TimeSpan.FromMinutes(amount),
                's' => TimeSpan.FromSeconds(amount),
                _ => throw MalformedLifetime(raw),
            };
        }

        if (total <= TimeSpan.Zero)
        {
            throw MalformedLifetime(raw);
        }

        return total;
    }

    private static InvalidOperationException MalformedLifetime(string? raw) =>
        new(
            $"{SessionLifetimeSetting} value '{raw}' is not a valid duration. Use a number followed " +
            "by a unit: d (days), h (hours), m (minutes) or s (seconds), e.g. 30d, 12h or 1h30m.");
}
